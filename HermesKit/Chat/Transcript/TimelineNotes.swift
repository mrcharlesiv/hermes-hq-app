// [transcript] Timeline notes in words (docs/spec/3x-transcript.md §2.2, row L303). Ported from
// `S/fe-convo-r6.ts` (modelSwitchLabel, failedTurnNote, silentRun). `Hydration.timelineContent` words stored rows by
// their `display_kind`; this covers the rows that carry no kind (older gateways, the live system message) and the
// rule that a failed-turn note next to its error card is not drawn twice.

import Foundation

nonisolated enum TimelineNote: Equatable, Sendable {
    /// Drawn as a centred note with these words.
    case words(String)
    /// Not drawn.
    case hidden
    /// Left as it is.
    case raw(String)
}

nonisolated enum TimelineNotes {
    private static let modelSwitch = TRx(#"^\[System: The active model for this chat has changed to (\S+?)(?: via provider (\S+?))?\. From this point"#)
    private static let failedTurn = TRx(#"^(?:Your request was not processed\.|This turn did not complete\.)"#)
    /// The note of a turn that failed ("Your request was not processed. …").
    static func isFailedTurn(_ words: String) -> Bool { failedTurn.test(words) }
    private static let systemNote = TRx(#"^\[System:\s*([\s\S]*?)\]?\s*$"#)
    /// A reply's text longer than this (UTF-8 bytes, all text parts) can't be a padded "[SILENT]".
    static let silentScanLimit = 256

    /// "Model changed to Opus 5.5"; the id when it has no name; "Model changed" when the text names none.
    static func modelSwitchLabel(_ content: String, displayName: (String) -> String = { ModelNames.displayModelName($0) }) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let groups = modelSwitch.groups(text), let id = groups[1], !id.isEmpty else { return "Model changed" }
        let name = displayName(id).trimmingCharacters(in: .whitespacesAndNewlines)
        // An id too long to be a name stays out of the timeline (bad data): the row says what happened.
        if id.count > 80 { return "Model changed" }
        return "Model changed to \(name.isEmpty ? id : name)"
    }

    static func isModelSwitch(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[System: The active model for this chat has changed")
    }

    /// Hermes closing a failed turn (`agent/turn_failure_copy.py`).
    static func isFailedTurnNote(_ text: String) -> Bool {
        failedTurn.test(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A system row's text as the timeline reads it. `errorNearby`: an error card covers the same turn.
    static func note(_ text: String, errorNearby: Bool = false,
                     displayName: (String) -> String = { ModelNames.displayModelName($0) }) -> TimelineNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFailedTurnNote(trimmed) { return errorNearby ? .hidden : .raw(text) }
        guard trimmed.hasPrefix("[System:") else { return .raw(text) }
        if isModelSwitch(trimmed) { return .words(modelSwitchLabel(trimmed, displayName: displayName)) }
        guard let groups = systemNote.groups(trimmed), let inside = groups[1] else { return .raw(text) }
        let words = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? .hidden : .words(words)
    }

    /// The display pass over a chat's messages (run with the delivery resolvers, before rows are built):
    /// - a system message is worded (`note`); a failed-turn note beside an error card of its turn is dropped;
    /// - a user or assistant message that is only a `[System: …]` model-switch sentence becomes the note;
    /// - a settled assistant message whose whole text is `[SILENT]` (or a stand-in, `Hydration.isSilentWords`) becomes the silent-run note (its tool calls stay);
    /// - an "[IMPORTANT: …]" process note becomes a note with the words inside;
    /// - your request as Hermes restates it after compressing the chat becomes a note that opens on it.
    /// The same array comes back when nothing changed.
    static func resolve(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage]?
        func text(_ m: ChatMessage) -> String? {
            guard m.parts.count == 1, case .text(let t) = m.parts[0] else { return nil }
            return t
        }
        for index in messages.indices {
            let m = messages[index]
            switch m.role {
            case .system:
                guard let t = text(m) else { continue }
                let near = (index > 0 && messages[index - 1].role == .assistant && messages[index - 1].error != nil)
                    || (index + 1 < messages.count && messages[index + 1].role == .assistant && messages[index + 1].error != nil)
                switch note(t, errorNearby: near) {
                case .hidden:
                    // Kept in place with nothing to draw: the rows' ranges index this array like the session's own.
                    if out == nil { out = messages }
                    out![index].parts = [.text("")]
                case .words(let words):
                    if out == nil { out = messages }
                    out![index].parts = [.text(words)]
                case .raw: break
                }
            case .user:
                guard m.sender == nil, let t = text(m) else { continue }
                if isModelSwitch(t) {
                    if out == nil { out = messages }
                    out![index].role = .system
                    out![index].parts = [.text(modelSwitchLabel(t))]
                } else if let words = CronDeliveries.processNote(t) {
                    if out == nil { out = messages }
                    out![index].role = .system
                    if let split = processHeadline(words) {
                        // The desktop's ProcessNotificationNote: the first line is the note, the rest opens under it.
                        out![index].parts = [.text(ChatText.clip(split.headline, max: 600))]
                        out![index].report = split.detail
                    } else {
                        out![index].parts = [.text(ChatText.clip(words, max: 600))]
                    }
                } else if let restated = restatedRequest(t) {
                    if out == nil { out = messages }
                    if restated.before.isEmpty {
                        // [restated] Your request again, as Hermes restates it after compressing the chat mid-turn: a
                        // note that opens on it (owner, 2026-10-30: "[STILL IN PROGRESS — …]" and the whole voice memo
                        // drew as a second bubble of yours, under the reply to the first).
                        out![index].role = .system
                        out![index].parts = [.text(restatedTitle)]
                        out![index].report = restated.request
                    } else {
                        // The carrier kept earlier words in front of it: they stay; the repeat goes.
                        out![index].parts = [.text(restated.before)]
                    }
                } else if t.contains("(Task id "), let asked = TodoWords.askShown(t) {
                    // [tasks] A question about a task: your words, not the task's details sent with them.
                    if out == nil { out = messages }
                    out![index].parts = [.text(asked)]
                } else if t.hasPrefix("[ASYNC DELEGATION") {
                    // [helper-note] A helper's note that reached the chat as a prompt (a queued prompt, an older
                    // gateway): the one line history draws, what the helper reported opening under it (owner,
                    // 2026-10-30: the whole block, job output and all, read as a bubble of the owner's).
                    if out == nil { out = messages }
                    out![index].role = .system
                    out![index].parts = [.text(helperTitle(t))]
                    out![index].report = Hydration.asyncResultBody(t)
                }
            case .assistant:
                guard m.sender == nil, !m.isStreaming, m.error == nil else { continue }
                // The live path of the silent run: text parts that together are "[SILENT]"; tool rows of the turn stay.
                // [perf] This runs over every reply on every flush: a reply longer than a padded sentinel is skipped
                // before its text is joined and trimmed (utf8.count of a native string doesn't scan it).
                var length = 0
                for part in m.parts { if case .text(let t) = part { length += t.utf8.count } }
                guard length <= Self.silentScanLimit else { continue }
                var words = ""
                var hasOther = false
                for part in m.parts {
                    if case .text(let t) = part { words += t } else if case .tool = part { hasOther = true }
                }
                guard Hydration.isSilentWords(words) else { continue }
                if out == nil { out = messages }
                if hasOther {
                    // Keep the turn's tool calls; the sentinel text goes, and the note follows as its own row.
                    out![index].parts = m.parts.filter { if case .text = $0 { return false } else { return true } }
                    out![index].silentNote = true
                } else {
                    out![index].role = .system
                    out![index].parts = [.text(Hydration.silentRunText)]
                }
            }
        }
        return out ?? messages
    }

    /// [restated] The note's words for a request Hermes restated after compressing the chat.
    static let restatedTitle = "Chat compressed · still on your request"

    /// [restated] Hermes's header on the unfinished request it restates past a compaction, so the model carries on
    /// (H:agent/context_compressor.py `_INFLIGHT_TASK_REPLAY_HEADER`): "[STILL IN PROGRESS — this is the active
    /// request, restated after the compaction boundary because it was not finished yet. Continue it; do not start
    /// over.]". The row stands in for your message, which history still holds (and the chat draws) where you sent it.
    private static let restatedHeader = TRx(#"(?m)^[ \t]*\[STILL IN PROGRESS\s*[—–-][^\]\n]*\bcompaction\b[^\]\n]*\][ \t]*\r?\n?"#)

    /// [restated] A message holding a restated request: the words before Hermes's header (a carrier that kept earlier
    /// words, else empty) and the request after it, in a line's words ("Voice Memo: …" for a memo). Nil for any other.
    static func restatedRequest(_ text: String) -> (before: String, request: String)? {
        guard text.contains("[STILL IN PROGRESS"), let range = restatedHeader.firstRange(text) else { return nil }
        let before = ChatText.trimmed(String(text[..<range.lowerBound]))
        let after = ChatText.trimmed(String(text[range.upperBound...]))
        return (before, VoiceMemo.parse(after)?.transcriptLine ?? after)
    }

    /// [helper-note] Hermes's own title for a helper's note, read from its text (the row's `display_text` when it has
    /// one): "Subagent Task Completed: <goal>" for one helper, "2 background agents finished" for a batch. The chat's
    /// line words these as it words the stored note (BackgroundResults.plainTitle).
    static func helperTitle(_ content: String) -> String {
        if content.hasPrefix("[ASYNC DELEGATION BATCH") {
            let count = helperCount.groups(content)?[1]
            return count.map { "\($0) background agents finished" } ?? "Background agents finished"
        }
        let status = helperStatus.groups(content)?[1]?.lowercased() ?? ""
        let outcome = ["failed": "Failed", "error": "Failed", "rejected": "Failed", "cancelled": "Cancelled",
                       "interrupted": "Interrupted", "timeout": "Timed Out", "stalled": "Stalled"][status] ?? "Completed"
        guard let goal = helperGoal.groups(content)?[1]?.trimmingCharacters(in: .whitespaces), !goal.isEmpty else {
            return outcome == "Completed" ? "1 background agent finished" : "Subagent Task \(outcome)"
        }
        return "Subagent Task \(outcome): \(goal.count > 200 ? String(goal.prefix(197)) + "..." : goal)"
    }

    private static let helperCount = TRx(#"(\d+) subagents?\b"#)
    private static let helperStatus = TRx(#"(?m)^Status: *([A-Za-z_]+)"#)
    private static let helperGoal = TRx(#"(?m)^Original goal: *(.+)$"#)

    /// "Background process proc_… completed normally (exit code 0)." over "Command: …\nOutput: …" (the words inside
    /// "[IMPORTANT: …]"): the note in plain words ("Background task finished: npm test"), with the gateway's own line
    /// (its process id and exit code) at the top of what opens under it. A line whose outcome can't be read stays as
    /// it is; nil for other notes, and for an unread line with nothing under it.
    static func processHeadline(_ words: String) -> (headline: String, detail: String)? {
        guard words.hasPrefix("Background process ") else { return nil }
        let lines = words.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !first.isEmpty else { return nil }
        if let plain = processWords(first, detail: rest) { return (plain, rest.isEmpty ? first : first + "\n" + rest) }
        guard !rest.isEmpty else { return nil }
        return (first, rest)
    }

    private static let exitCode = TRx(#"exit[ _]?code\W{0,3}(-?\d+)"#, [.caseInsensitive])
    private static let failedWords = TRx(#"\b(?:failed|killed|crashed|errored|timed out)\b"#, [.caseInsensitive])
    private static let finishedWords = TRx(#"\b(?:completed|finished|exited|done)\b"#, [.caseInsensitive])

    /// "Background task finished" (exit code 0, or finished with no code) / "Background task failed" (any other code,
    /// or failed words), plus the command's short name when the detail names one; nil when the line says neither.
    static func processWords(_ line: String, detail: String) -> String? {
        let ok: Bool
        if let code = exitCode.groups(line)?[1].flatMap({ Int($0) }) { ok = code == 0 }
        else if failedWords.test(line) { ok = false }
        else if finishedWords.test(line) { ok = true }
        else { return nil }
        let words = ok ? "Background task finished" : "Background task failed"
        guard let command = shortCommand(detail) else { return words }
        return "\(words): \(command)"
    }

    /// The "Command:" line's command in short, cut to 40 characters: paths without their folders, and a script without
    /// the interpreter that runs it ("…/bin/python3 /Users/…/tools/report.py --week" → "report.py --week"; owner,
    /// 2026-10-28: the line was a python path).
    static func shortCommand(_ detail: String) -> String? {
        guard let line = detail.split(separator: "\n").first(where: { $0.hasPrefix("Command:") }) else { return nil }
        let command = ToolWords.collapseHeredocs(String(line.dropFirst("Command:".count)))
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var parts = command.split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            guard word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("./") else { return String(word) }
            return word.split(separator: "/").last.map(String.init) ?? String(word)
        }
        guard !parts.isEmpty else { return nil }
        if interpreter.test(parts[0]), let script = parts.indices.dropFirst().first(where: { !parts[$0].hasPrefix("-") }),
           scriptFile.test(parts[script]) {
            parts.removeSubrange(0..<script)
        }
        let short = parts.joined(separator: " ")
        return short.count > 40 ? String(short.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : short
    }

    private static let interpreter = TRx(#"^(?:python[0-9.]*|node|bun|deno|ruby|perl|bash|sh|zsh)$"#)
    private static let scriptFile = TRx(#"\.(?:py|js|mjs|cjs|ts|rb|pl|sh|zsh)$"#)

    /// While a reply streams, a text that could still turn out to be "[SILENT]" is held back (never drawn, not even
    /// for a frame): a prefix of the sentinel no longer than it.
    static func holdsBack(streamingText text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 8 && "[SILENT]".hasPrefix(t)
    }
}
