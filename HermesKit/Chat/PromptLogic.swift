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
        return ClarifyDraft(page: page, stages: stages)
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
        let left = Int((seenAt.timeIntervalSince1970 + timeout - now.timeIntervalSince1970).rounded(.up))
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
            return ClarifyQA(question: question, answer: answer, unanswered: blank && item["status"]?.string == "unanswered")
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
