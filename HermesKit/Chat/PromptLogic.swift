// Pure rules for stream "questions" (docs/spec/1x-questions.md), ported from the web app with its tests' expectations:
// clarify normalisation (V:desktop/src/store/clarify.ts), the dock's staging (W:src/phone-question-dock.tsx:32-84),
// approval expiry (W:src/approval-expiry.ts) and the settled Q&A card (V:…/clarify/parse.ts, HA:tools/clarify_tool.py).

import Foundation

/// The handshake kill switch (spec 1x §9 R1): `HQNNoServerRequests` in the environment or user defaults skips
/// `client.capabilities` (M1 behaviour), for diagnosis.
nonisolated enum ServerRequestsSwitch {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["HQNNoServerRequests"] != nil { return false }
        return !UserDefaults.standard.bool(forKey: "HQNNoServerRequests")
    }()
}

// MARK: - Clarify questions

nonisolated enum ClarifyText {
    static let recommendedLabel = "(Recommended)"
    static let maxChoiceChars = 8000

    /// A choice minus a trailing "(Recommended)" (what is sent and what the settled card shows).
    static func bareChoice(_ choice: String) -> String {
        guard choice.hasSuffix(recommendedLabel) else { return choice }
        return String(choice.dropLast(recommendedLabel.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isRecommended(_ choice: String) -> Bool { bareChoice(choice) != choice }

    /// `normalizeQuestions` (clarify.ts:52-102): non-blank qid and question (trimmed); choices that are non-blank
    /// strings whose bare text is ≤ 8,000 characters (none left → an open question); multi-select only with choices.
    static func normalize(_ questions: JSONValue?) -> [ClarifyQuestion] {
        var out: [ClarifyQuestion] = []
        for entry in questions?.array ?? [] {
            guard let row = entry.object else { continue }
            let qid = row["qid"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let question = row["question"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !qid.isEmpty, !question.isEmpty else { continue }
            let choices = (row["choices"]?.array ?? []).compactMap(\.string).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bareChoice($0).count <= maxChoiceChars
            }
            out.append(ClarifyQuestion(qid: qid, question: question, choices: choices.isEmpty ? nil : choices,
                                       multiSelect: row["multi_select"]?.bool == true && !choices.isEmpty))
        }
        return out
    }

    /// A replay's `answers` map: qid → answer (nil = skipped). Non-string answers are JSON-encoded.
    static func lockedAnswers(_ value: JSONValue?) -> [String: String?] {
        var out: [String: String?] = [:]
        for (qid, answer) in value?.object ?? [:] {
            switch answer {
            case .null: out[qid] = .some(nil)
            case .string(let s): out[qid] = .some(s)
            default: out[qid] = .some(ChatJSON.stringify(answer))
            }
        }
        return out
    }
}

/// The dock's staging (web `stagedAnswer`, `toggleStage`, `openOther`, `replayStage`, `sentRows`).
nonisolated enum ClarifyStaging {
    /// What one question answers, exactly as the web card sends it (nil: unanswered). Multi-select: a JSON array
    /// string of bare picks plus the typed text.
    static func stagedAnswer(_ question: ClarifyQuestion, _ stage: ClarifyStage = ClarifyStage()) -> String? {
        let hasChoices = !(question.choices ?? []).isEmpty
        let draft = stage.other || !hasChoices ? stage.draft.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if question.multiSelect {
            let combined = stage.choices.map(ClarifyText.bareChoice) + (draft.isEmpty ? [] : [draft])
            return combined.isEmpty ? nil : jsonArray(combined)
        }
        if let first = stage.choices.first { return ClarifyText.bareChoice(first) }
        return draft.isEmpty ? nil : draft
    }

    /// A tap on a choice: single-select replaces (and closes "Something else"), multi-select toggles.
    static func toggle(_ question: ClarifyQuestion, _ stage: ClarifyStage, _ choice: String) -> ClarifyStage {
        guard question.multiSelect else { return ClarifyStage(choices: [choice], draft: stage.draft, other: false) }
        var next = stage
        if let i = next.choices.firstIndex(of: choice) { next.choices.remove(at: i) } else { next.choices.append(choice) }
        return next
    }

    /// "Something else": single-select drops the picked choice; multi-select keeps it beside the text.
    static func openOther(_ question: ClarifyQuestion, _ stage: ClarifyStage) -> ClarifyStage {
        question.multiSelect ? ClarifyStage(choices: stage.choices, draft: stage.draft, other: true)
            : ClarifyStage(choices: [], draft: stage.draft, other: true)
    }

    /// A reconnect's already-locked answer shows as picked (nil: nothing locked for it).
    static func replay(_ question: ClarifyQuestion, _ answer: String??) -> ClarifyStage? {
        guard let outer = answer, let answer = outer else { return nil }
        var answers = [answer]
        if question.multiSelect, let data = answer.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any], parsed.allSatisfy({ $0 is String }) {
            answers = parsed.compactMap { $0 as? String }
        }
        let choices = (question.choices ?? []).filter { answers.contains(ClarifyText.bareChoice($0)) }
        let rest = answers.filter { value in !choices.contains { ClarifyText.bareChoice($0) == value } }
        if !choices.isEmpty && rest.isEmpty { return ClarifyStage(choices: choices, draft: "", other: false) }
        return ClarifyStage(choices: choices, draft: rest.joined(separator: ", "), other: !(question.choices ?? []).isEmpty)
    }

    /// The note after Send ("" when skipped, nil = no answer); multi-select answers joined with ", ".
    static func sentRows(_ questions: [ClarifyQuestion], _ stages: [String: ClarifyStage], skipped: Bool = false) -> [SentClarifyRow] {
        questions.map { q in
            if skipped { return SentClarifyRow(question: q.question, answer: "") }
            let answer = stagedAnswer(q, stages[q.qid] ?? ClarifyStage())
            if let answer, q.multiSelect, let data = answer.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return SentClarifyRow(question: q.question, answer: list.joined(separator: ", "))
            }
            return SentClarifyRow(question: q.question, answer: answer)
        }
    }

    /// The draft the dock opens with: replayed locks first, local picks win (web `QuestionPages` initial state).
    static func initialDraft(_ prompt: ClarifyPrompt, saved: ClarifyDraft?) -> ClarifyDraft {
        var stages: [String: ClarifyStage] = [:]
        for q in prompt.questions {
            if let stage = replay(q, prompt.lockedAnswers[q.qid]) { stages[q.qid] = stage }
        }
        for (qid, stage) in saved?.stages ?? [:] { stages[qid] = stage }
        let page = min(max(0, saved?.page ?? 0), max(0, prompt.questions.count - 1))
        return ClarifyDraft(page: page, stages: stages, minimized: saved?.minimized ?? false)
    }

    /// `JSON.stringify` of a string array (no spaces, `/` unescaped).
    static func jsonArray(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Approval expiry (W:src/approval-expiry.ts)

nonisolated enum ApprovalExpiry {
    static let defaultTimeout: TimeInterval = 300
    static let expired = "Expired"

    /// "Expires within 0:42", "Expires within 4 min", or "Expired" (left > 90 s → minutes, rounded up). Past 99 minutes
    /// (an `approvals.timeout` set that long) it counts hours, "Expires within 2 h", so it fits the card's space for
    /// "Expires within 99 min" instead of being cut.
    static func label(seenAt: Date, timeout: TimeInterval, now: Date = Date()) -> String {
        let remaining = seenAt.timeIntervalSince1970 + timeout - now.timeIntervalSince1970
        guard !remaining.isNaN, remaining > 0 else { return expired }
        let capped = min(remaining, 365.0 * 100.0 * 86_400.0)
        let left = Int(capped.rounded(.up))
        if left <= 0 { return expired }
        if left > 99 * 60 { return "Expires within \(Int((Double(left) / 3600).rounded(.up))) h" }
        if left > 90 { return "Expires within \(Int((Double(left) / 60).rounded(.up))) min" }
        return String(format: "Expires within %d:%02d", left / 60, left % 60)
    }

    /// The countdown a card shows: `stale` (the estimate ran out on a timeout read before it was due) reads
    /// "Expires within 0:00" until a fresh read agrees.
    static func countdown(seenAt: Date, timeout: TimeInterval?, readAt: Date?, now: Date = Date()) -> (label: String, stale: Bool) {
        guard let timeout, let readAt else { return ("", false) }
        let due = seenAt.addingTimeInterval(timeout)
        let stale = now >= due && readAt < due
        let text = label(seenAt: seenAt, timeout: timeout, now: now)
        return (stale && text == expired ? "Expires within 0:00" : text, stale)
    }

    /// `approvals.timeout` from a `/api/config` answer: absent or non-positive → 300.
    static func timeout(fromConfig config: JSONValue?) -> TimeInterval {
        guard let value = config?["approvals"]?["timeout"]?.double, value.isFinite, value > 0 else { return defaultTimeout }
        return value
    }
}

// MARK: - The settled clarify card (HA:tools/clarify_tool.py `_result`)

nonisolated struct ClarifyQA: Equatable, Sendable, Hashable, Codable {
    var question: String
    var answer: String
    /// Blank and `status == "unanswered"` → "No answer"; any other blank → "Skipped".
    var unanswered: Bool
    /// The choices it offered (`choices_offered`), for answering it later; nil = an open question (or a card cached
    /// before they were kept).
    var choices: [String]? = nil
}

nonisolated enum ClarifySettled {
    /// `result.responses[]` → rows, from a live `tool.complete` result (an object, or its JSON text) or a history `tool`
    /// row's content (JSON text). nil when there is no `responses` array (the generic tool row stays).
    static func parse(_ result: JSONValue?) -> [ClarifyQA]? {
        guard var result else { return nil }
        if case .string(let text) = result {
            guard let data = text.data(using: .utf8), let parsed = try? JSONValue.parseFast(data) else { return nil }
            result = parsed
        }
        guard let responses = result["responses"]?.array else { return nil }
        return responses.compactMap { item in
            guard let question = item["question"]?.string else { return nil }
            let answer: String
            switch item["user_response"] {
            case .string(let s)?: answer = s
            case .array(let list)?: answer = list.compactMap(\.string).joined(separator: ", ")
            case .number?, .bool?: answer = ChatJSON.stringify(item["user_response"]!)
            default: answer = ""
            }
            let blank = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let offered = (item["choices_offered"]?.array ?? []).compactMap(\.string)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return ClarifyQA(question: question, answer: answer, unanswered: blank && item["status"]?.string == "unanswered",
                             choices: offered.isEmpty ? nil : offered)
        }
    }

    /// The marker a clarify `ToolCall.summary` starts with when it carries the settled rows (parsed once, at fold or
    /// hydration, so the rows reach the row builder and the transcript cache without the 8 KB detail cap).
    static let marker = "\u{2063}clarify:"

    static func summary(_ rows: [ClarifyQA]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(rows)) ?? Data("[]".utf8)
        return marker + String(decoding: data, as: UTF8.self)
    }

    /// The clarify tool's summary: the settled rows when its result has them, else `fallback`.
    static func summary(name: String, result: JSONValue?, fallback: String?) -> String? {
        guard name == "clarify", let rows = parse(result) else { return fallback }
        return summary(rows)
    }

    static func rows(fromSummary summary: String?) -> [ClarifyQA]? {
        guard let summary, summary.hasPrefix(marker) else { return nil }
        return try? JSONDecoder().decode([ClarifyQA].self, from: Data(summary.dropFirst(marker.count).utf8))
    }
}

// MARK: - A skipped question answered later

/// A question that went unanswered (you were away, or skipped it) can still be answered from its card: the answer goes
/// into the chat as a message of yours naming the card, and the card then shows it (on every device, after a reload),
/// the way a draft card's answer does (HermesKit/Drafts/DraftCards.swift). The bot's clarify call is long over, so a
/// plain message is the only way back to it.
nonisolated enum ClarifyLate {
    /// One card's answers found in the chat: the question (on one line) → its answer, and the index of the newest
    /// message that gave them (`Int.max`: still queued behind a running reply).
    struct Found: Equatable, Sendable, Hashable {
        var answers: [String: String]
        var index: Int
    }

    static let markLead = "[Hermes HQ question "
    private static let mark = TRx(#"^\s*\[Hermes HQ question (q-[0-9a-f]{8}): answer\]"#)

    /// A question on one line (how the message writes it and how a card looks it up).
    static func flat(_ question: String) -> String {
        question.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The card's name in the message: the same for the same questions on every device and after a reload.
    static func key(_ questions: [String]) -> String {
        String(format: "q-%08x", ChatText.fnv1a(questions.map(flat).joined(separator: "\n")))
    }

    /// What the card's Send sends: the mark, a line saying what it is, then each question and its answer.
    static func message(key: String, answers: [(question: String, answer: String)]) -> String {
        let lead = answers.count == 1 ? "My answer to the question you asked earlier, which went unanswered:"
            : "My answers to the questions you asked earlier, which went unanswered:"
        let body = answers.map { "Q: \(flat($0.question))\nA: \($0.answer.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return "\(markLead)\(key): answer]\n\(lead)\n\n" + body.joined(separator: "\n\n")
    }

    /// The card a message of yours answers, and its answers by question (on one line).
    static func answer(in text: String) -> (key: String, answers: [String: String])? {
        guard text.drop(while: \.isWhitespace).hasPrefix(markLead), let groups = mark.groups(text), let key = groups[1] else { return nil }
        guard let gap = text.range(of: "\n\nQ: ") else { return (key, [:]) }
        var out: [String: String] = [:]
        for chunk in text[gap.upperBound...].components(separatedBy: "\n\nQ: ") {
            guard let split = chunk.range(of: "\nA: ") else { continue }
            let question = flat(String(chunk[..<split.lowerBound]))
            let answer = chunk[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty && !answer.isEmpty { out[question] = answer }
        }
        return (key, out)
    }

    /// Your bubble's words: the answers alone, one a line, in the order written (the card above shows the questions).
    static func bubbleWords(_ text: String) -> String? {
        guard answer(in: text) != nil else { return nil }
        var words: [String] = []
        for chunk in text.components(separatedBy: "\n\nQ: ").dropFirst() {
            guard let split = chunk.range(of: "\nA: ") else { continue }
            let answer = chunk[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { words.append(answer) }
        }
        return words.isEmpty ? nil : words.joined(separator: "\n")
    }

    /// Every card the chat's messages answer, by key (answers merge; the newest wins). `queued`: answers still waiting
    /// behind a running reply count too (they are newest).
    static func answers(_ messages: [ChatMessage], queued: [String] = []) -> [String: Found] {
        var out: [String: Found] = [:]
        func take(_ text: String, _ index: Int) {
            guard let found = answer(in: text) else { return }
            var entry = out[found.key] ?? Found(answers: [:], index: index)
            entry.answers.merge(found.answers) { _, new in new }
            entry.index = index
            out[found.key] = entry
        }
        for (index, message) in messages.enumerated() where message.role == .user {
            for part in message.parts { if case .text(let text) = part { take(text, index) } }
        }
        for text in queued { take(text, .max) }
        return out
    }

    /// A settled card's rows with the answers given later filled in; `later` is true when any were.
    static func filled(_ rows: [ClarifyQA], _ found: Found?) -> (rows: [ClarifyQA], later: Bool) {
        guard let found, !found.answers.isEmpty else { return (rows, false) }
        var later = false
        let out = rows.map { row -> ClarifyQA in
            guard row.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let answer = found.answers[flat(row.question)] else { return row }
            later = true
            var next = row
            next.answer = answer
            next.unanswered = false
            return next
        }
        return (out, later)
    }

    /// [calm-chat] Whether `messages[index]` is a late clarify answer immediately following the assistant message
    /// containing that settled clarify card (the card right above already fills in the answer).
    static func isAdjacentAnswerEcho(_ messages: [ChatMessage], at index: Int, key: String) -> Bool {
        var scan = index - 1
        while scan >= 0 {
            let prev = messages[scan]
            if prev.role == .system { scan -= 1; continue }
            guard prev.role == .assistant else { return false }
            return prev.parts.contains { part in
                guard case .tool(let c) = part, c.name == "clarify", c.state != .running,
                      let rows = ClarifySettled.rows(fromSummary: c.summary), !rows.isEmpty else { return false }
                return Self.key(rows.map(\.question)) == key
            }
        }
        return false
    }

    /// [calm-chat] True when at least one later normal human turn or later clarify call follows `messageId`, so an
    /// unanswered clarify card stops displaying a bright live "Answer Now" pill in scrollback.
    static func hasLaterHumanTurn(after messageId: String, in messages: [ChatMessage]) -> Bool {
        guard let at = messages.lastIndex(where: { $0.id == messageId }), at + 1 < messages.count else { return false }
        for m in messages[(at + 1)...] {
            if isUserTurn(m) { return true }
            if m.role == .assistant, m.parts.contains(where: { if case .tool(let c) = $0, c.name == "clarify" { return true } else { return false } }) {
                return true
            }
        }
        return false
    }

    /// [calm-chat] True once the user sends a new normal message after `messageId` (and after any late answer `lateIndex`
    /// filling this card). Answered clarify cards stay open throughout the turn they belong to — across follow-up prose,
    /// chained clarify calls, and bot-to-bot exchanges — and fold only once the user moves on with a new turn.
    static func hasMovedPastTurn(after messageId: String, answeredAt lateIndex: Int? = nil, in messages: [ChatMessage]) -> Bool {
        if lateIndex == .max { return false }
        guard let at = messages.lastIndex(where: { $0.id == messageId }) else { return false }
        let anchor = max(at, lateIndex ?? at)
        guard anchor + 1 < messages.count else { return false }
        return messages[(anchor + 1)...].contains(where: isUserTurn)
    }

    private static func isUserTurn(_ message: ChatMessage) -> Bool {
        guard DraftCards.isNormalHumanTurn(message) else { return false }
        let text = message.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Message from 🤖 ") || text.contains("[INTERNAL NOTIFICATION") || text.hasPrefix("[Cronjob \"") {
            return false
        }
        return true
    }

    /// [calm-chat] Lookback for `ChatRowModel.rebuildNewest`: when a later human turn, clarify call, or late answer
    /// arrives, reach back to earlier settled clarify cards so they fold / drop Answer Now live.
    static func reach(from: Int, floor: Int, in messages: [ChatMessage]) -> Int {
        guard from > floor, from < messages.count else { return from }
        var triggers = false
        for m in messages[from...] {
            if isUserTurn(m) { triggers = true; break }
            if m.role == .user, m.parts.contains(where: { if case .text(let t) = $0 { return answer(in: t) != nil } else { return false } }) {
                triggers = true; break
            }
            if m.role == .assistant, m.parts.contains(where: { part in
                if case .tool(let c) = part { return c.name == "clarify" }
                return false
            }) {
                triggers = true; break
            }
        }
        guard triggers else { return from }
        let scanFloor = max(floor, from - 120)
        var lowest = from
        var i = from - 1
        while i >= scanFloor {
            if messages[i].role == .assistant, messages[i].parts.contains(where: {
                if case .tool(let c) = $0, c.name == "clarify", c.state != .running { return true } else { return false }
            }) {
                lowest = i
            }
            i -= 1
        }
        return lowest
    }
}
