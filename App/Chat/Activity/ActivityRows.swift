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
    /// File Changes (Settings › Chat): Off, no "N files changed" card; Folded, its one line until tapped; Open, the card.
    var fileChanges: FileChangesLook = .open
    var showFileChanges: Bool {
        get { fileChanges != .off }
        set { fileChanges = newValue ? .open : .off }
    }
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
    /// Observed completed helpers from earlier batches. Only request-scoped helper grouping reads this cache.
    var retainedSubagents: [SubagentProgress] = []
    /// Delegate calls represented by the request's single helper line. Original calls stay available in its details.
    var consolidatedHelperCalls: Set<String> = []
    /// The explained provider wait for the waiting capsule.
    var providerWait: String?
    /// The chat's profile and stored session (the generated image's download).
    var profile = ""
    /// The newest message when a hidden goal continuation went out (`StepRules.isWorking`).
    var turnAnchor: String?
    /// Generated images whose good path wouldn't load: drawn as the "Open image: …" link row (§11.3).
    var failedImages: Set<String> = []
    /// [chat-mark-done] The Tasks store's tasks as the close cards read them (a snapshot of `TodoTaskStates`).
    var taskStates = TodoTaskStates.Snapshot()
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
    /// [task-lists] A bot's offer of a list or a batch of tasks, with its buttons (board 4).
    case tasksOffer(TasksOfferRow)
    /// [goals step 3] A bot's goal, plan, check-in or tasks for a goal, with its buttons (boards 3 to 5).
    case goalOffer(GoalOfferRow)
    /// [chat-mark-done] A bot's offer to close a task of yours (Mark Done / Keep Open), or its word that it marked one
    /// done because you said so (Undo).
    case taskClose(TaskCloseRow)
}

/// [chat-mark-done] One task a reply's `tasks_update` offered to close, or closed because you said so. `state` is the
/// task now (read from the Tasks store when the row is built); the layout is the same in every state, so the card
/// never jumps as you answer it.
nonisolated struct TaskCloseRow {
    var messageId: String
    var taskId: String
    var title: String
    /// "Hermes: looks done · Ivy confirmed by email" (the task page's line); nil on the asked card.
    var line: String?
    /// The bot marked it done because you said so (no offer, no Keep Open).
    var asked: Bool
    var state: TodoCloseCards.State
    /// The gateway takes no writes: the buttons dimmed, as on the task's page.
    var readOnly: Bool
}

/// [goals step 3] What a reply's `goals_offer` offered, read from the store by its id (the tool's answer is the id
/// alone). Its words are settled when the row is built; what became of it (accepted, undone) is the cell's to show, so
/// the card is the same height in every state.
nonisolated struct GoalOfferRow {
    nonisolated struct Line: Hashable {
        var title: String
        /// "Nov 24", "Thu", or "" (milestones and tasks alike).
        var due: String
        /// The bot it is for (its face and name at the row's end); nil: you.
        var bot: String?
        var botName: String?
        var head: JSONValue?
        var milestone = false
    }
    var messageId: String
    var offer: TodoOffer
    /// "Hermes · Monday check-in" (the check-in only).
    var kicker: String?
    var kickerBot: String?
    var kickerHead: JSONValue?
    var title: String
    /// "plan", "new goal", "add 2 tasks?".
    var tag: String
    var summary: String?
    var milestonesHeader: String?
    var milestones: [Line]
    var milestonesMore: Int
    var tasksHeader: String?
    var tasks: [Line]
    var tasksMore: Int
    /// [goals set-up] A plan's "Built on" lines (quiet words, three at most) and what accepting it also sets on the goal
    /// ("Name", "Why", "Number", "By"): the offer's own words, the same in every state.
    var builtOn: [String] = []
    var setup: [GoalSetupRow] = []
    /// The quiet line under the buttons: "Keep the Goal, No Plan" (a button), or the lead's note (words).
    var quiet: String?
    var quietIsButton: Bool
    var color: TodoListColor
    var spoken: String
}

/// [task-lists] What a reply's `tasks_offer` offered. What became of it (accepted, undone) is the cell's to show:
/// the row is the same height in every state.
nonisolated struct TasksOfferRow {
    var messageId: String
    var offer: TodoOffer
    var title: String
    /// Each line's words and when it's due ("Tomorrow"), at most `shown`, then "+4 more".
    var lines: [(title: String, due: String)]
    var more: Int

    static let shown = 6
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
    /// [calm-chat] Once the chat moves past this reply, fold to one quiet line that expands on tap.
    var folded = false
    var opened = false
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
    /// [files] File Changes › Folded (owner 2026-11-20): the card stands as one line, "8 files changed +49 −11 ⌄", like
    /// a reply's work line. False under Open: the card alone, as before.
    var folded = false
    /// Folded only: the line was tapped open, and the card hangs under it (`ChatRow.filesOpenKey` in `expanded`).
    var opened = false
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
    /// [files] The `expanded` key that holds a folded files line open (the row's own id is its "Show All N Files").
    static func filesOpenKey(_ rowId: String) -> String { rowId + "#open" }

    /// [files] The "N files changed" card's files; nil for every other row.
    var changedFiles: ChangedFilesRow? {
        if case .activity(.changedFiles(let c)) = kind { return c }
        return nil
    }

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
            if case .delegate(let cardGoals, _, _, _)? = call.card, goals.isEmpty { goals = cardGoals }
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
        guard input.activity.showFileChanges, !m.isStreaming, !input.activity.folding.contains(m.id), !edits.isEmpty else { return nil }
        let files = ChangedFiles.derive(calls: edits)
        guard !files.isEmpty else { return nil }
        return changedFilesRow(id: "\(m.id)|files", messageId: m.id, files: files, input: input)
    }

    /// The card for these files ([files] also the one card that stands for several replies' cards: UpdateGroups.swift).
    static func changedFilesRow(id: String, messageId: String, files: [ChangedFile], input: ChatRowBuilder.Input) -> ChatRow {
        let showAll = input.expanded.contains(id)
        let folded = input.activity.fileChanges == .folded
        let opened = folded && input.expanded.contains(ChatRow.filesOpenKey(id))
        var h = Hasher()
        for f in files { h.combine(f.path); h.combine(f.name); h.combine(f.added); h.combine(f.removed); h.combine(f.edits) }
        h.combine(showAll)
        h.combine(folded)
        h.combine(opened)
        return ChatRow(id: id, messageId: messageId, scope: input.scope, fingerprint: h.finalize(),
                       kind: .activity(.changedFiles(ChangedFilesRow(messageId: messageId, files: files, showAll: showAll,
                                                                      folded: folded, opened: opened))),
                       gapAbove: folded ? 0 : 8, variant: (showAll ? 1 : 0) + (folded ? 2 : 0) + (opened ? 4 : 0))
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
        let id = "\(m.id)|tasks"
        let folded = hasLaterConversation(after: m, in: input.messages)
        let opened = folded && input.expanded.contains(id)
        var h = Hasher()
        h.combine(tasks); h.combine(lines); h.combine(undone); h.combine(helping); h.combine(botName)
        h.combine(folded); h.combine(opened)
        return ChatRow(id: id, messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                       kind: .activity(.tasksAdded(TasksAddedRow(messageId: m.id, tasks: tasks, lines: lines, undone: undone,
                                                                 helping: helping, botName: botName, folded: folded, opened: opened))),
                       gapAbove: folded ? 4 : 8, variant: (folded ? 1 : 0) + (opened ? 2 : 0))
    }

    /// [calm-chat] True once a later user message or a later assistant message with visible prose/cards follows `m`.
    static func hasLaterConversation(after m: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard let at = messages.lastIndex(where: { $0.id == m.id }), at + 1 < messages.count else { return false }
        for later in messages[(at + 1)...] {
            switch later.role {
            case .user:
                if later.sender == nil { return true }
            case .assistant:
                let hasContent = later.parts.contains { part in
                    switch part {
                    case .text(let t): return !ReasoningTags.isBlank(t)
                    case .tool(let c):
                        return c.name == DraftCards.tool || c.name == AskCards.tool
                            || ShoppingCards.tools.contains(c.name)
                            || c.name == "tasks_add" || c.name == "tasks_offer" || c.name == "goals_offer"
                    case .reasoning: return false
                    }
                }
                if hasContent { return true }
            case .system:
                break
            }
        }
        return false
    }

    /// [calm-chat] Lookback for `ChatRowModel.rebuildNewest`: when a new turn lands, reach back to the most recent
    /// earlier `tasks_add`/`tasks_update` message at or after `floor` so its card folds live.
    static func tasksAddedReach(from: Int, floor: Int, in messages: [ChatMessage]) -> Int {
        guard from > floor, from < messages.count else { return from }
        let triggersFold = messages[from...].contains { m in
            if m.role == .user && m.sender == nil { return true }
            guard m.role == .assistant else { return false }
            return m.parts.contains { part in
                switch part {
                case .text(let t): return !ReasoningTags.isBlank(t)
                case .tool(let c):
                    return c.name == DraftCards.tool || c.name == AskCards.tool
                        || ShoppingCards.tools.contains(c.name)
                        || c.name == "tasks_add" || c.name == "tasks_offer" || c.name == "goals_offer"
                case .reasoning: return false
                }
            }
        }
        guard triggersFold else { return from }
        var i = from - 1
        while i >= floor {
            if messages[i].role == .assistant, messages[i].parts.contains(where: { part in
                if case .tool(let c) = part, c.name == "tasks_add" || c.name == "tasks_update", case .tasksAdded? = c.card { return true }
                return false
            }) {
                return i
            }
            i -= 1
        }
        return from
    }

    // MARK: A bot's offer ([task-lists], board 4)

    /// Under a settled reply whose bot offered a list or a batch of tasks: one card per offer.
    static func tasksOfferRows(_ m: ChatMessage, calls: [ToolCall], input: ChatRowBuilder.Input) -> [ChatRow] {
        guard !m.isStreaming else { return [] }
        var seen: Set<String> = []
        return calls.compactMap { call -> ChatRow? in
            guard call.state == .done, case .tasksOffer(let offer)? = call.card, seen.insert(offer.id).inserted else { return nil }
            let title = TodoLists.chatTitle(offer, botName: { _ in input.speakerName })
            let all: [(title: String, due: String)] = offer.tasks.isEmpty
                ? offer.move.map { ($0.title, "") }
                : offer.tasks.map { task in (task.title, TodoDates.due(task.due).map { TodoWords.day($0.date, now: input.now) } ?? "") }
            let lines = Array(all.prefix(TasksOfferRow.shown))
            var h = Hasher()
            h.combine(offer); h.combine(title); h.combine(lines.map(\.due))
            return ChatRow(id: "\(m.id)|offer|\(offer.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .activity(.tasksOffer(TasksOfferRow(messageId: m.id, offer: offer, title: title, lines: lines,
                                                                     more: all.count - lines.count))),
                           gapAbove: 8, variant: 0)
        }
    }

    // MARK: A bot's offer to close a task ([chat-mark-done])

    /// Under a settled reply whose bot offered to close a task of yours (`tasks_update` with `offer_done`), or marked
    /// one done because you said so (`status: done`, `asked`): one card per task, its last call in the reply. A result,
    /// as the two cards above: Tool Call Style and Hide Steps don't touch it. What it shows is the task now; one the
    /// store hasn't read yet asks for it, and the row comes once it has (`TodoTaskStates.changed` rebuilds the chat),
    /// as a goal's offer does. Only the chat's newest card for a task keeps its buttons.
    static func taskCloseRows(_ m: ChatMessage, calls: [ToolCall], input: ChatRowBuilder.Input) -> [ChatRow] {
        guard !m.isStreaming else { return [] }
        let found = closeCards(calls)
        guard !found.isEmpty else { return [] }
        let states = input.activity.taskStates
        let own = input.activity.profile
        let name: (String?) -> String = { profile in
            let id = profile ?? own
            if id == own || id.isEmpty { return input.speakerName }
            return input.bots.first { $0.profile == id }?.name ?? (id == "default" ? "Hermes" : id.capitalized)
        }
        return found.compactMap { task -> ChatRow? in
            let newest = newestCloseCard(task.id, in: input.messages) == m.id
            let offerAt = task.closeOffer?.at
            guard let state = TodoCloseCards.state(asked: task.askedDone, offer: task.closeOffer, id: task.id, newest: newest,
                                                   in: states) else {
                TodoTaskStates.want(task.id, at: offerAt)
                return nil
            }
            // A list only from disk, or an offer newer than the store's: read it again (the card shows what it has).
            if !states.read || TodoCloseCards.newer(offerAt, than: states.tasks[task.id]?.offer?.at) {
                TodoTaskStates.want(task.id, at: offerAt)
            }
            let row = TaskCloseRow(messageId: m.id, taskId: task.id, title: task.title,
                                   line: task.askedDone ? nil : task.closeOffer.map { TodoLists.closeLine($0, botName: name) },
                                   asked: task.askedDone, state: state, readOnly: states.readOnly)
            var h = Hasher()
            h.combine(row.taskId); h.combine(row.title); h.combine(row.line); h.combine(row.asked); h.combine(row.state)
            h.combine(row.readOnly)
            return ChatRow(id: "\(m.id)|close|\(task.id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .activity(.taskClose(row)), gapAbove: 8, variant: 0)
        }
    }

    /// The tasks a reply's `tasks_update` calls offered to close or closed as asked, each once (its last call).
    static func closeCards(_ calls: [ToolCall]) -> [AddedTask] {
        var found: [AddedTask] = []
        for call in calls where call.state == .done && call.name == "tasks_update" {
            guard case .tasksAdded(let tasks)? = call.card else { continue }
            for task in tasks where task.closeOffer != nil || task.askedDone {
                if let i = found.firstIndex(where: { $0.id == task.id }) { found[i] = task } else { found.append(task) }
            }
        }
        return found
    }

    /// The id of the chat's newest reply with a close card for this task.
    static func newestCloseCard(_ id: String, in messages: [ChatMessage]) -> String? {
        for m in messages.reversed() where m.role == .assistant {
            let calls = m.parts.compactMap { part -> ToolCall? in if case .tool(let c) = part, c.name == "tasks_update" { return c } else { return nil } }
            if closeCards(calls).contains(where: { $0.id == id }) { return m.id }
        }
        return nil
    }

    // MARK: A goal's offer ([goals step 3], boards 3 to 5)

    /// Under a settled reply whose bot called `goals_offer`: one card per offer the app has read. One it hasn't read
    /// yet asks the store for it, and the row comes once it has (`TodoOfferStates.changed` rebuilds the chat).
    static func goalOfferRows(_ m: ChatMessage, calls: [ToolCall], input: ChatRowBuilder.Input) -> [ChatRow] {
        guard !m.isStreaming else { return [] }
        var seen: Set<String> = []
        return calls.compactMap { call -> ChatRow? in
            guard call.state == .done, case .goalOffer(let id, _)? = call.card, seen.insert(id).inserted else { return nil }
            guard let offer = TodoOfferStates.live(id).offer else { TodoOfferStates.want(id); return nil }
            guard !offer.held else { return nil }   // a helper's tasks wait for the lead's check-in, not for you
            let row = goalOfferRow(m, offer: offer, input: input)
            var h = Hasher()
            h.combine(row.title); h.combine(row.kicker); h.combine(row.tag); h.combine(row.summary)
            h.combine(row.milestones); h.combine(row.tasks); h.combine(row.quiet); h.combine(row.milestonesMore); h.combine(row.tasksMore)
            h.combine(row.color); h.combine(offer.id); h.combine(row.builtOn); h.combine(row.setup)
            return ChatRow(id: "\(m.id)|goal-offer|\(id)", messageId: m.id, scope: input.scope, fingerprint: h.finalize(),
                           kind: .activity(.goalOffer(row)), gapAbove: 8, variant: 0)
        }
    }

    /// The card's words, read once: names from the chat's roster (the reply's own bot by its name).
    static func goalOfferRow(_ m: ChatMessage, offer: TodoOffer, input: ChatRowBuilder.Input) -> GoalOfferRow {
        let goal = TodoOfferStates.goal(offer.goal)
        func name(_ id: String?) -> String {
            guard let id, !id.isEmpty else { return input.botName }
            if let seat = input.bots.first(where: { $0.profile == id }) { return seat.name }
            if id == "default" { return "Hermes" }
            return id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
        }
        func head(_ id: String?) -> JSONValue? { id.flatMap { id in input.bots.first { $0.profile == id }?.head } }
        func day(_ due: String?) -> String { TodoDates.due(due).map { TodoWords.day($0.date, now: input.now) } ?? "" }
        let milestones = offer.milestones.map { GoalOfferRow.Line(title: $0.title, due: day($0.due), milestone: true) }
        let tasks = offer.tasks.map { task -> GoalOfferRow.Line in
            let bot = task.botFor(offer)
            return GoalOfferRow.Line(title: task.title, due: day(task.due), bot: bot, botName: bot.map { name($0) }, head: head(bot))
        }
        let shownMilestones = Array(milestones.prefix(GoalOffers.shown))
        let shownTasks = Array(tasks.prefix(GoalOffers.shown))
        var tasksHeader: String?
        switch offer.kind {
        case "checkin": tasksHeader = tasks.isEmpty ? nil : "This week"
        case "tasks": tasksHeader = nil
        default: tasksHeader = tasks.isEmpty ? nil : "This week · \(TodoLists.count(tasks.count))"
        }
        var quiet: String?
        var quietIsButton = false
        switch offer.kind {
        case "goal" where !offer.milestones.isEmpty || !offer.tasks.isEmpty, "plan":
            quiet = "Keep the Goal, No Plan"; quietIsButton = true
        case "tasks":
            quiet = GoalOffers.leadNote(offer, goal: goal, botName: { name($0) })
        default: break
        }
        let title = offer.title.isEmpty ? (goal?.title ?? "A goal") : offer.title
        let summary = offer.kind == "checkin" ? offer.summary : (offer.kind == "goal" ? offer.why : "")
        return GoalOfferRow(
            messageId: m.id, offer: offer,
            kicker: offer.kind == "checkin" ? GoalOffers.checkinHead(offer, goal: goal, botName: { name($0) }) : nil,
            kickerBot: offer.kind == "checkin" ? offer.bot : nil, kickerHead: offer.kind == "checkin" ? head(offer.bot) : nil,
            title: title, tag: offer.kind == "checkin" ? "" : GoalOffers.tag(offer),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary.trimmingCharacters(in: .whitespacesAndNewlines),
            milestonesHeader: milestones.isEmpty ? nil : GoalOffers.milestoneCount(milestones.count),
            milestones: shownMilestones, milestonesMore: milestones.count - shownMilestones.count,
            tasksHeader: tasksHeader, tasks: shownTasks, tasksMore: tasks.count - shownTasks.count,
            builtOn: GoalOffers.builtOn(offer), setup: GoalOffers.setupRows(offer, now: input.now),
            quiet: quiet, quietIsButton: quietIsButton, color: goal?.tint ?? .blue,
            spoken: GoalOffers.spoken(offer, goal: goal, botName: { name($0) }))
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
    /// [files] File Changes › Folded: the one line ("8 files changed +49 −11"), spanning the chat (the cell centres its
    /// glyph, words and caret in it, as an update group's line). Nil under Open.
    var lineFrame: CGRect?
    var lineText: NSAttributedString?
    var lineFont: UIFont?
    /// Folded and tapped open: the card is drawn under the line (false: the line alone).
    var opened = false
    /// Folded: the card's top line carries only "Review ›" — the line above it already says how many files.
    var cardShown = true
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
    /// [calm-chat] Folded older tasks card: a quiet one-line disclosure row that expands the card on tap.
    var lineFrame: CGRect? = nil
    var lineText: NSAttributedString? = nil
    var lineFont: UIFont? = nil
    var opened = false
    var cardShown = true
}

/// [goals step 3] A goal's offer: a kicker (the check-in's "Hermes · Monday check-in"), the goal's mark, name and tag,
/// the bot's summary, the milestones and the tasks (each with who), then the foot: a row of buttons, or one line of
/// words with Undo, and the quiet line. The same frames in every state.
nonisolated struct GoalOfferLayout: @unchecked Sendable {
    nonisolated struct Line: @unchecked Sendable {
        var frame: CGRect
        var markFrame: CGRect
        var titleFrame: CGRect
        var trailFrame: CGRect
        var line: GoalOfferRow.Line
    }
    nonisolated struct Header: @unchecked Sendable {
        var frame: CGRect
        var text: String
    }
    /// [goals set-up] One row of what a plan also sets: its label and its value.
    nonisolated struct SetupLine: @unchecked Sendable {
        var labelFrame: CGRect
        var valueFrame: CGRect
        var row: GoalSetupRow
    }
    var cardFrame: CGRect
    var kickerFrame: CGRect?
    var markFrame: CGRect
    var titleFrame: CGRect
    var summaryFrame: CGRect?
    var headers: [Header]
    /// [goals set-up] The "Built on" lines (quiet words) and the set-up rows.
    var notes: [Header] = []
    var setupLines: [SetupLine] = []
    var lines: [Line]
    /// "2 more ›" under a section (its frame and the words).
    var mores: [Header]
    var buttonsFrame: CGRect
    var quietFrame: CGRect?
    var font: UIFont
    var detailFont: UIFont
    var smallFont: UIFont
    var row: GoalOfferRow
}

/// [task-lists] A bot's offer: the title, why, a row per task, "+4 more", then the foot (a filled button or one line
/// of words, and a row of quiet buttons), the same in every state.
nonisolated struct TasksOfferLayout: @unchecked Sendable {
    nonisolated struct Line: @unchecked Sendable {
        var frame: CGRect
        var circleFrame: CGRect
        var titleFrame: CGRect
        var title: String
        var dueFrame: CGRect
        var due: String
    }
    var cardFrame: CGRect
    var badgeFrame: CGRect
    var titleFrame: CGRect
    var title: String
    var whyFrame: CGRect?
    var lines: [Line]
    var moreFrame: CGRect?
    var more = 0
    var mainFrame: CGRect
    var footFrame: CGRect
    var font: UIFont
    var detailFont: UIFont
    var offer: TodoOffer
}

/// [chat-mark-done] A bot's offer to close a task: its line (the task page's words), the task's title, then the foot: the
/// two buttons, or one line of words with Undo at its end. The same frames in every state.
nonisolated struct TaskCloseLayout: @unchecked Sendable {
    var cardFrame: CGRect
    var markFrame: CGRect?
    var lineFrame: CGRect?
    var circleFrame: CGRect
    var titleFrame: CGRect
    var footFrame: CGRect
    var doneFrame: CGRect
    var keepFrame: CGRect
    var statusFrame: CGRect
    var undoFrame: CGRect
    var font: UIFont
    var detailFont: UIFont
    var row: TaskCloseRow
}

nonisolated enum ActivityLayout: @unchecked Sendable {
    case toolBubble(ToolBubbleLayout)
    case delegate(DelegateCardLayout)
    case image(ImageCardLayout)
    case changedFiles(ChangedFilesLayout)
    case diffPreview(DiffPreviewLayout)
    case tasksAdded(TasksAddedLayout)
    case tasksOffer(TasksOfferLayout)
    case goalOffer(GoalOfferLayout)
    case taskClose(TaskCloseLayout)
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
        case .tasksOffer(let t): return tasksOffer(t, row: row, width: width, style: style)
        case .goalOffer(let g): return goalOffer(g, row: row, width: width, style: style)
        case .taskClose(let t): return taskClose(t, row: row, width: width, style: style)
        }
    }

    // MARK: A bot's offer ([task-lists])

    private static func height(_ text: String, font: UIFont, width: CGFloat, lines: Int) -> CGFloat {
        let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return min(ceil(box.height), ceil(font.lineHeight) * CGFloat(lines))
    }

    /// [calm-chat] Cohesive compact card width on Mac (360 pt at 77% Catalyst scale felt disproportionately skinny
    /// beside wider reply cards); iPhone/iPad keep 360 pt.
    private static var compactCardCap: CGFloat { DeviceWord.isMac ? 480 : 360 }

    private static func tasksOffer(_ t: TasksOfferRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = min(TextLayout.replyWidth(width), compactCardCap)
        let font = HQFont.face(ofSize: (16 * style.chromeBody / 17).rounded())
        let headFont = HQFont.face(ofSize: font.pointSize, weight: .semibold)
        let detailFont = HQFont.face(ofSize: (13 * style.chromeBody / 17).rounded())
        let lineH = ceil(font.lineHeight), detailH = ceil(detailFont.lineHeight)
        let pad: CGFloat = 14
        let left = ChatMetrics.sideInset
        let top = max(0, row.gapAbove)
        let badge = ceil(headFont.pointSize * 1.15)
        let titleW = max(40, columnW - 2 * pad - badge - 8)
        let titleH = height(t.title, font: headFont, width: titleW, lines: 2)
        var y = top + 12
        let titleFrame = CGRect(x: left + pad + badge + 8, y: y, width: titleW, height: titleH)
        let badgeFrame = CGRect(x: left + pad, y: y + ((ceil(headFont.lineHeight) - badge) / 2).rounded(), width: badge, height: badge)
        y += titleH
        var whyFrame: CGRect?
        let why = t.offer.why.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty {
            let whyH = height(why, font: detailFont, width: columnW - 2 * pad, lines: 3)
            whyFrame = CGRect(x: left + pad, y: y + 4, width: columnW - 2 * pad, height: whyH)
            y += 4 + whyH
        }
        y += 8
        let circle = ceil(detailFont.pointSize * 1.25)
        let rowH = max(34, lineH + 12)
        let dueFont = detailFont
        var lines: [TasksOfferLayout.Line] = []
        for line in t.lines {
            let dueW = line.due.isEmpty ? 0 : ceil((line.due as NSString).size(withAttributes: [.font: dueFont]).width)
            let textX = left + pad + circle + 10
            let textW = max(40, left + columnW - pad - textX - (dueW > 0 ? dueW + 10 : 0))
            lines.append(.init(frame: CGRect(x: left, y: y, width: columnW, height: rowH),
                               circleFrame: CGRect(x: left + pad, y: y + ((rowH - circle) / 2).rounded(), width: circle, height: circle),
                               titleFrame: CGRect(x: textX, y: y + ((rowH - lineH) / 2).rounded(), width: textW, height: lineH), title: line.title,
                               dueFrame: CGRect(x: left + columnW - pad - dueW, y: y + ((rowH - detailH) / 2).rounded(), width: dueW, height: detailH),
                               due: line.due))
            y += rowH
        }
        var moreFrame: CGRect?
        if t.more > 0 {
            moreFrame = CGRect(x: left + pad + circle + 10, y: y + 2, width: columnW - 2 * pad - circle - 10, height: detailH)
            y += detailH + 6
        }
        y += 8
        let mainFrame = CGRect(x: left + pad, y: y, width: columnW - 2 * pad, height: max(38, lineH + 16))
        y = mainFrame.maxY
        let footFrame = CGRect(x: left, y: y, width: columnW, height: 44)
        y += 44
        return RowLayout(height: ceil(y + 2), content: .activity(.tasksOffer(TasksOfferLayout(
            cardFrame: CGRect(x: left, y: top, width: columnW, height: y - top), badgeFrame: badgeFrame, titleFrame: titleFrame,
            title: t.title, whyFrame: whyFrame, lines: lines, moreFrame: moreFrame, more: t.more, mainFrame: mainFrame,
            footFrame: footFrame, font: font, detailFont: detailFont, offer: t.offer))))
    }

    // MARK: A bot's offer to close a task ([chat-mark-done])

    /// The foot holds both buttons on one row when they fit, else one under the other (the largest text sizes); its
    /// words, when answered, get the same height, measured for the longest they can say, so no state moves the card.
    private static func taskClose(_ t: TaskCloseRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = min(TextLayout.replyWidth(width), compactCardCap)
        let font = HQFont.face(ofSize: (16 * style.chromeBody / 17).rounded())
        let buttonFont = HQFont.face(ofSize: font.pointSize, weight: .semibold)
        let detailFont = HQFont.face(ofSize: (14 * style.chromeBody / 17).rounded())
        let lineH = ceil(font.lineHeight)
        let pad: CGFloat = 14
        let left = ChatMetrics.sideInset
        let top = max(0, row.gapAbove)
        let innerW = columnW - 2 * pad
        var y = top + 12
        var markFrame: CGRect?, lineFrame: CGRect?
        if let line = t.line {
            let mark = ceil(detailFont.pointSize * 1.1)
            let w = max(40, innerW - mark - 7)
            let h = height(line, font: detailFont, width: w, lines: 4)
            markFrame = CGRect(x: left + pad, y: y + ((ceil(detailFont.lineHeight) - mark) / 2).rounded(), width: mark, height: mark)
            lineFrame = CGRect(x: left + pad + mark + 7, y: y, width: w, height: h)
            y += h + 8
        }
        let circle = ceil(font.pointSize * 1.15)
        let titleW = max(40, innerW - circle - 9)
        let titleH = max(lineH, height(t.title, font: font, width: titleW, lines: 3))
        let circleFrame = CGRect(x: left + pad, y: y + ((lineH - circle) / 2).rounded(), width: circle, height: circle)
        let titleFrame = CGRect(x: left + pad + circle + 9, y: y, width: titleW, height: titleH)
        y += titleH + 12
        // The foot: Mark Done (filled) and Keep Open (quiet), side by side when they fit.
        let buttonH = max(40, lineH + 18)
        func wide(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: buttonFont]).width) + 28 }
        let doneW = wide("Mark Done"), keepW = wide("Keep Open")
        var doneFrame: CGRect, keepFrame: CGRect
        var footH: CGFloat
        if doneW + 8 + keepW <= innerW {
            doneFrame = CGRect(x: left + pad, y: y, width: doneW, height: buttonH)
            keepFrame = CGRect(x: doneFrame.maxX + 8, y: y, width: keepW, height: buttonH)
            footH = buttonH
        } else {
            doneFrame = CGRect(x: left + pad, y: y, width: innerW, height: buttonH)
            keepFrame = CGRect(x: left + pad, y: y + buttonH + 6, width: innerW, height: buttonH)
            footH = 2 * buttonH + 6
        }
        // Answered: the words at the start, Undo at the end (the words wrap at the largest sizes).
        let undoW = min(innerW / 2, wide("Undo"))
        let mark = ceil(font.pointSize * 1.1)
        let wordsW = max(40, innerW - undoW - 8 - mark - 7)
        let wordsH = TodoCloseCards.allWords.map { height($0, font: buttonFont, width: wordsW, lines: 3) }.max() ?? lineH
        footH = max(footH, wordsH + 12)
        let footFrame = CGRect(x: left + pad, y: y, width: innerW, height: footH)
        let undoH = max(44, buttonH)
        let undoFrame = CGRect(x: footFrame.maxX - undoW, y: y + ((footH - undoH) / 2).rounded(), width: undoW, height: undoH)
        let statusFrame = CGRect(x: left + pad, y: y, width: innerW - undoW - 8, height: footH)
        y += footH + 12
        return RowLayout(height: ceil(y + 2), content: .activity(.taskClose(TaskCloseLayout(
            cardFrame: CGRect(x: left, y: top, width: columnW, height: y - top), markFrame: markFrame, lineFrame: lineFrame,
            circleFrame: circleFrame, titleFrame: titleFrame, footFrame: footFrame, doneFrame: doneFrame, keepFrame: keepFrame,
            statusFrame: statusFrame, undoFrame: undoFrame, font: font, detailFont: detailFont, row: t))))
    }

    // MARK: A goal's offer ([goals step 3])

    private static func goalOffer(_ g: GoalOfferRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = min(TextLayout.replyWidth(width), DeviceWord.isMac ? 500 : 380)
        let font = HQFont.face(ofSize: (16 * style.chromeBody / 17).rounded())
        let headFont = HQFont.face(ofSize: font.pointSize, weight: .semibold)
        let detailFont = HQFont.face(ofSize: (14 * style.chromeBody / 17).rounded())
        let smallFont = HQFont.face(ofSize: (12 * style.chromeBody / 17).rounded(), weight: .semibold)
        let lineH = ceil(detailFont.lineHeight), smallH = ceil(smallFont.lineHeight)
        let pad: CGFloat = 14
        let left = ChatMetrics.sideInset
        let top = max(0, row.gapAbove)
        let innerW = columnW - 2 * pad
        var y = top + 12
        var kickerFrame: CGRect?
        if g.kicker != nil {
            kickerFrame = CGRect(x: left + pad, y: y, width: innerW, height: ceil(detailFont.lineHeight))
            y += ceil(detailFont.lineHeight) + 4
        }
        let mark = ceil(headFont.pointSize * 1.05)
        let titleW = max(40, innerW - mark - 7)
        let titleText = g.tag.isEmpty ? g.title : g.title + "  " + g.tag
        let titleH = height(titleText, font: headFont, width: titleW, lines: 2)
        let markFrame = CGRect(x: left + pad, y: y + ((ceil(headFont.lineHeight) - mark) / 2).rounded(), width: mark, height: mark)
        let titleFrame = CGRect(x: left + pad + mark + 7, y: y, width: titleW, height: titleH)
        y += titleH
        var summaryFrame: CGRect?
        if let summary = g.summary {
            let h = height(summary, font: detailFont, width: innerW, lines: 4)
            summaryFrame = CGRect(x: left + pad, y: y + 4, width: innerW, height: h)
            y += 4 + h
        }
        var headers: [GoalOfferLayout.Header] = []
        var lines: [GoalOfferLayout.Line] = []
        var mores: [GoalOfferLayout.Header] = []
        let rowH = max(30, lineH + 12)
        let box = ceil(detailFont.pointSize * 1.15)
        let trailW = min(120, (innerW * 0.34).rounded())
        func section(_ header: String?, _ items: [GoalOfferRow.Line], more: Int) {
            guard !items.isEmpty else { return }
            y += 8
            if let header {
                headers.append(.init(frame: CGRect(x: left + pad, y: y, width: innerW, height: smallH), text: header.uppercased()))
                y += smallH + 2
            }
            for item in items {
                let textX = left + pad + box + 10
                let hasTrail = !item.due.isEmpty || item.bot != nil || !item.milestone
                let textW = max(40, left + columnW - pad - textX - (hasTrail ? trailW + 8 : 0))
                lines.append(.init(frame: CGRect(x: left, y: y, width: columnW, height: rowH),
                                   markFrame: CGRect(x: left + pad, y: y + ((rowH - box) / 2).rounded(), width: box, height: box),
                                   titleFrame: CGRect(x: textX, y: y + ((rowH - lineH) / 2).rounded(), width: textW, height: lineH),
                                   trailFrame: CGRect(x: left + columnW - pad - trailW, y: y + ((rowH - lineH) / 2).rounded(), width: trailW, height: lineH),
                                   line: item))
                y += rowH
            }
            if more > 0 {
                mores.append(.init(frame: CGRect(x: left + pad, y: y, width: innerW, height: max(28, lineH + 8)), text: "\(more) more ›"))
                y += max(28, lineH + 8)
            }
        }
        // [goals set-up] Under the title: what the plan rests on, then what accepting it also sets. Fixed words, so the
        // card keeps one height in every state.
        var notes: [GoalOfferLayout.Header] = []
        var setupLines: [GoalOfferLayout.SetupLine] = []
        if !g.builtOn.isEmpty {
            y += 8
            headers.append(.init(frame: CGRect(x: left + pad, y: y, width: innerW, height: smallH), text: GoalOffers.builtOnHeader.uppercased()))
            y += smallH + 3
            for words in g.builtOn {
                let h = height(words, font: detailFont, width: innerW, lines: 2)
                notes.append(.init(frame: CGRect(x: left + pad, y: y, width: innerW, height: h), text: words))
                y += h + 3
            }
        }
        if !g.setup.isEmpty {
            y += 8
            headers.append(.init(frame: CGRect(x: left + pad, y: y, width: innerW, height: smallH), text: GoalOffers.setupHeader.uppercased()))
            y += smallH + 3
            let labelW = ceil(g.setup.map { ($0.label as NSString).size(withAttributes: [.font: detailFont]).width }.max() ?? 0)
            let valueX = left + pad + labelW + 10
            let valueW = max(40, left + columnW - pad - valueX)
            for row in g.setup {
                let h = height(row.value, font: detailFont, width: valueW, lines: 2)
                setupLines.append(.init(labelFrame: CGRect(x: left + pad, y: y, width: labelW, height: lineH),
                                        valueFrame: CGRect(x: valueX, y: y, width: valueW, height: h), row: row))
                y += max(lineH, h) + 4
            }
        }
        section(g.milestonesHeader, g.milestones, more: g.milestonesMore)
        section(g.tasksHeader, g.tasks, more: g.tasksMore)
        y += 12
        let buttonsFrame = CGRect(x: left + pad, y: y, width: innerW, height: max(40, ceil(font.lineHeight) + 18))
        y = buttonsFrame.maxY
        var quietFrame: CGRect?
        if let quiet = g.quiet {
            let h = g.quietIsButton ? max(36, ceil(detailFont.lineHeight) + 16) : height(quiet, font: detailFont, width: innerW, lines: 3) + 14
            quietFrame = CGRect(x: left + pad, y: y + 2, width: innerW, height: h)
            y += 2 + h
        } else {
            y += 12
        }
        return RowLayout(height: ceil(y + 2), content: .activity(.goalOffer(GoalOfferLayout(
            cardFrame: CGRect(x: left, y: top, width: columnW, height: y - top), kickerFrame: kickerFrame, markFrame: markFrame,
            titleFrame: titleFrame, summaryFrame: summaryFrame, headers: headers, notes: notes, setupLines: setupLines,
            lines: lines, mores: mores,
            buttonsFrame: buttonsFrame, quietFrame: quietFrame, font: font, detailFont: detailFont, smallFont: smallFont, row: g))))
    }

    // MARK: Added to Tasks ([tasks])

    private static func tasksAdded(_ t: TasksAddedRow, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let columnW = min(TextLayout.replyWidth(width), compactCardCap)
        let font = HQFont.face(ofSize: (16 * style.chromeBody / 17).rounded())
        let detailFont = HQFont.face(ofSize: (13 * style.chromeBody / 17).rounded())
        let lineH = ceil(font.lineHeight), detailH = ceil(detailFont.lineHeight)
        let pad: CGFloat = 14
        let left = ChatMetrics.sideInset
        var top = max(0, row.gapAbove)
        var lineFrame: CGRect?, lineText: NSAttributedString?, lineFont: UIFont?
        if t.folded {
            let notice = style.notice
            let boldNotice = HQFont.face(ofSize: notice.pointSize, weight: .semibold)
            let rowH = max(32, ceil(notice.lineHeight) + 10)
            let maxLineW = PromptLayout.cardWidth(for: width)
            lineFrame = CGRect(x: left, y: top, width: maxLineW, height: rowH)
            let lead = t.undone ? "Removed from Tasks" : t.helping ? "\(t.botName) Is Helping" : "Added to Tasks"
            let out = NSMutableAttributedString(string: lead, attributes: [.font: boldNotice, .foregroundColor: ChatPalette.label2])
            if let first = t.tasks.first?.title, !first.isEmpty {
                let extra = t.tasks.count > 1 ? " (+\(t.tasks.count - 1) more)" : ""
                out.append(NSAttributedString(string: " · \(first)\(extra)", attributes: [.font: notice, .foregroundColor: ChatPalette.label2]))
            }
            lineText = out
            lineFont = notice
            if !t.opened {
                return RowLayout(height: ceil(top + rowH + 2), content: .activity(.tasksAdded(TasksAddedLayout(
                    cardFrame: .zero, headerFrame: .zero, undone: t.undone, font: font, detailFont: detailFont,
                    lines: [], footerFrame: .zero, helping: t.helping, botName: t.botName, helpFrame: nil,
                    lineFrame: lineFrame, lineText: lineText, lineFont: lineFont, opened: false, cardShown: false))))
            }
            top += rowH + 6
        }
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
        return RowLayout(height: ceil(y + 4), content: .activity(.tasksAdded(TasksAddedLayout(
            cardFrame: cardFrame, headerFrame: headerFrame, undone: t.undone, font: font, detailFont: detailFont,
            lines: lines, footerFrame: footerFrame, helping: t.helping, botName: t.botName, helpFrame: helpFrame,
            lineFrame: lineFrame, lineText: lineText, lineFont: lineFont, opened: t.opened, cardShown: true))))
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
        HQFont.face(ofSize: (14 * style.chromeBody / 17).rounded())
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
        var top = max(0, row.gapAbove)
        // [files] Folded: the work line's own row (40 pt, the notice face), its words and the summed +/− centred in it.
        var lineFrame: CGRect?, lineText: NSAttributedString?, lineFont: UIFont?
        if c.folded {
            let notice = style.notice
            let rowH = max(ChatMetrics.toolRowMin, ChatMetrics.toolRowPadV * 2 + ceil(notice.lineHeight))
            lineFrame = CGRect(x: left, y: top, width: width - 2 * left, height: rowH)
            lineText = filesLineText(c.files, font: notice)
            lineFont = notice
            if !c.opened {
                return RowLayout(height: ceil(top + rowH), content: .activity(.changedFiles(ChangedFilesLayout(
                    cardFrame: .zero, headerFrame: .zero, headerTitle: ChangedFiles.title(c.files.count), font: font, rows: [],
                    showAllFrame: nil, showAllTitle: nil, lineFrame: lineFrame, lineText: lineText, lineFont: lineFont,
                    opened: false, cardShown: false))))
            }
            top += rowH + 4   // the card 4 pt under its line, as an opened update line's
        }
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
        return RowLayout(height: ceil(y + (c.folded ? 8 : 2)), content: .activity(.changedFiles(ChangedFilesLayout(
            cardFrame: cardFrame, headerFrame: headerFrame, headerTitle: ChangedFiles.title(c.files.count),
            font: font, rows: rows, showAllFrame: showAllFrame, showAllTitle: showAllTitle,
            lineFrame: lineFrame, lineText: lineText, lineFont: lineFont, opened: c.opened, cardShown: true))))
    }

    /// [files] The folded line's words: "8 files changed", then every file's lines summed ("+49 −11", none when no
    /// file reported a count).
    static func filesLineText(_ files: [ChangedFile], font: UIFont) -> NSAttributedString {
        // Label 2 here (built off the main thread); on a chat picture's pill the cell takes the words to the primary label.
        let out = NSMutableAttributedString(string: ChangedFiles.title(files.count), attributes: [.font: font, .foregroundColor: ChatPalette.label2])
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        if added > 0 || removed > 0 {
            out.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            out.append(fileStats(added: added, removed: removed, font: font))
        }
        return out
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
