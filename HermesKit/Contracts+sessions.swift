// [sessions-m9] Sessions: Filter & Sort, chips, the pending line, Session Info (docs/spec/3x-sessions.md §3).
// The choices a user makes in the Filter & Sort menu (kept per gateway account on the device), a chat's status, the
// row's pending line, and the usage and fallback a chat reports for Session Info. Pure values.

import Foundation

// MARK: - What the user chose (§3.2)

/// Sort By (`V/store/layout.ts` orderings). Manual is the order the user dragged the rows into (kept on the device,
/// `SessionsDeviceState.chatOrder`); a drag picks it, as on the desktop.
nonisolated enum SessionSortBy: String, Codable, CaseIterable, Sendable { case updated, created, status, tokens, cost, manual }

/// Group By. Bot (the web phone left it out, `S/ui-lists/filter-menu.ts:90-91`) asked for by a tester, 2026-10-29: one
/// group per bot, as the desktop's All Profiles grouping.
nonisolated enum SessionGroupBy: String, Codable, CaseIterable, Sendable { case date, project, bot, status }

/// Row Detail: what the row's trailing text and second line may show (`PHONE_ROW_DETAIL`). Menu order.
nonisolated enum SessionRowDetail: String, Codable, CaseIterable, Sendable { case time = "updated", preview, tokens, cost }

/// A chat's one status (`V/store/session-dot-state.ts:89-98`), in menu order and sort rank 0…4.
nonisolated enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case needsInput = "needs-input", working, unread, draft, idle

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 4 }
}

nonisolated struct SessionsViewPrefs: Codable, Hashable, Sendable {
    var sortBy: SessionSortBy = .updated
    var groupBy: SessionGroupBy = .date
    var rowDetail: Set<SessionRowDetail> = [.preview, .time]
    var statusFilter: Set<SessionStatus> = []
    /// Project keys (`SessionProjects.key`).
    var projectFilter: Set<String> = []
    var showArchived = false
    /// [sessions-fresh] Show › Bot Faces: the face on Pinned's and Recent's rows (the chips keep theirs).
    var botFaces = true
    /// Show › Project Chats in Recent: off lists under "Recent" only the chats outside every project (Home's); a
    /// project's chats then show on its card alone (tester, 2026-11-08: "hide it from Recent too").
    var projectChatsInRecent = true
    /// [chats-projects] Show › Projects: the Chats side (Group By Recent) draws the projects' shortcut above Recent.
    /// Off by default: a tester found the projects on both sides of the switch confusing (2026-11-20), so the Chats
    /// side lists chats alone and the projects are the switch's other side; on brings the shortcut back as it was
    /// ([sessions-shape]). Project Chats in Recent only means something while it is on.
    var showProjects = false
    /// Row Detail › Preview under Group By Recent: one line of the last message under each Recent (and project card)
    /// chat's title. Its own setting, off by default, so the one-line Recent rows stay as they were; the other
    /// groupings keep `rowDetail`'s Preview (a tester, 2026-11-12: "toggling previews doesn't do anything").
    var recentPreview = false
    /// [project-pills] What the pills under the bar are: the bots, or under Group By Project the projects. Owner
    /// 2026-11-15: "the pills at the top are the projects so that you can filter by project", and then "I want this to
    /// replace the Projects view": Group By › Project is the project pills and their project pages. A project pill is
    /// Filter › Project with that one project. Setting it picks the grouping.
    var pills: SessionPills {
        get { groupBy == .project ? .projects : .bots }
        set {
            if newValue == .projects { groupBy = .project } else if groupBy == .project { groupBy = .date }
        }
    }

    init() {}

    /// [project-pills] Recent's one-line rows, and its own Preview switch: Group By Recent, and Group By Project (owner
    /// 2026-11-15, "all sessions sized like the way we have them sized in the Recent group by view").
    var recentRows: Bool { SessionListPipeline.isFresh(self) || (groupBy == .project && !SessionListPipeline.isFlat(self)) }

    /// What the rows show: `rowDetail`, with Preview from `recentPreview` under Group By Recent (and Project).
    var shownDetail: Set<SessionRowDetail> {
        guard recentRows else { return rowDetail }
        return recentPreview ? rowDetail.union([.preview]) : rowDetail.subtracting([.preview])
    }

    private enum CodingKeys: String, CodingKey { case sortBy, groupBy, rowDetail, statusFilter, projectFilter, showArchived, botFaces, projectChatsInRecent, showProjects, recentPreview }

    /// Lenient: a value this build does not know (a file from a newer one) reads as that field's default, never an error.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .sortBy), let value = SessionSortBy(rawValue: raw) { sortBy = value }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .groupBy), let value = SessionGroupBy(rawValue: raw) { groupBy = value }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .rowDetail) { rowDetail = Set(raw.compactMap(SessionRowDetail.init(rawValue:))) }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .statusFilter) { statusFilter = Set(raw.compactMap(SessionStatus.init(rawValue:))) }
        if let raw = try? c.decodeIfPresent([String].self, forKey: .projectFilter) { projectFilter = Set(raw) }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .showArchived) { showArchived = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .botFaces) { botFaces = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .projectChatsInRecent) { projectChatsInRecent = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .showProjects) { showProjects = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .recentPreview) { recentPreview = value }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sortBy.rawValue, forKey: .sortBy)
        try c.encode(groupBy.rawValue, forKey: .groupBy)
        try c.encode(SessionRowDetail.allCases.filter(rowDetail.contains).map(\.rawValue), forKey: .rowDetail)
        try c.encode(SessionStatus.allCases.filter(statusFilter.contains).map(\.rawValue), forKey: .statusFilter)
        try c.encode(projectFilter.sorted(), forKey: .projectFilter)
        try c.encode(showArchived, forKey: .showArchived)
        try c.encode(botFaces, forKey: .botFaces)
        try c.encode(projectChatsInRecent, forKey: .projectChatsInRecent)
        try c.encode(showProjects, forKey: .showProjects)
        try c.encode(recentPreview, forKey: .recentPreview)
    }
}

/// [project-pills] The Sessions pills: one per bot, or one per project.
nonisolated enum SessionPills: String, Codable, CaseIterable, Sendable { case bots, projects }

// MARK: - The row's pending line (§9.4)

/// What a chat's row says before its last message: a send that may never have arrived, else words waiting in the field.
nonisolated struct SessionPending: Hashable, Sendable {
    var failed: Bool
    var text: String

    /// `rowPending` (`S/ui-lists/row-pending.ts:15-20`): the lost send first, then a non-empty trimmed draft.
    static func pending(lost: String?, draft: String?) -> SessionPending? {
        if let lost { return SessionPending(failed: true, text: lost.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let typed = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : SessionPending(failed: false, text: typed)
    }

    var prefix: String { failed ? "Not Delivered:" : "Draft:" }
}

/// A coding row names the decision, current step or confirmed outcome. It isn't a transcript preview.
nonisolated enum CodingSessionSubtitle {
    static func line(_ row: SessionSummary) -> String {
        if row.pending?.failed == true { return "Your message wasn’t delivered" }
        if row.status == .needsInput { return row.inputDetail ?? "Waiting for you in chat" }
        if row.pending != nil { return "Draft not sent" }
        if row.isRunning || row.status == .working {
            return live(row.step ?? "")
        }
        if let result = row.lastResult, result != replyFallback { return result }
        if let pr = row.pullRequest, pr.state != .none, pr.state != .unknown {
            let name = pr.number.map { "PR #\($0)" } ?? "Pull request"
            switch pr.state {
            case .draft: return "\(name) is still a draft"
            case .open: return "\(name) is open"
            case .merged: return "\(name) merged"
            case .closed: return "\(name) closed"
            default: break
            }
        }
        return row.unread ? "Unread reply in chat" : row.lastResult ?? "No recent update"
    }

    private static let replyFallback = "Replied in chat"

    /// While the bot works: the tool call it is on, as every other Sessions row streams it ("Running npm test…",
    /// owner 2026-10-30), masked once more. "Working…" before the first step and while the reply writes.
    private static func live(_ step: String) -> String {
        let words = NotificationText.oneLine(NotificationText.redact(step))
        return words.isEmpty ? "Working…" : LiveSteps.line(words)
    }

    /// Fillers a reply opens with that say nothing about the work.
    private static let openers = ["done. ", "done! ", "done, ", "done: ", "done — ", "done - ", "all set. ", "all set! ",
                                  "sure. ", "sure! ", "okay. ", "okay, ", "ok. ", "ok, ", "got it. ", "great. ", "great news: "]

    /// When the turn ends: the reply's own summary, its first sentence (owner, 2026-11-20: tool calls while it works,
    /// the summary when it's done). A reply that opens with code or a masked secret says only that it replied.
    static func result(_ message: SessionLatestMessage) -> String? {
        if message.role == "user" { return "No reply yet" }
        guard message.role == "assistant" else { return nil }
        let raw = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.hasPrefix("```"), !raw.hasPrefix("$ ") else { return replyFallback }
        var words = NotificationText.oneLine(RosterPreview.cleanPreviewText(raw))
        while let lead = openers.first(where: { words.lowercased().hasPrefix($0) }) {
            words = String(words.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        if let end = words.range(of: #"[.!?](?=\s)"#, options: .regularExpression),
           words.distance(from: words.startIndex, to: end.lowerBound) >= 12 {
            words = String(words[..<end.upperBound])
        }
        let line = NotificationText.preview(words, max: 86)
        guard !line.isEmpty, !line.contains(NotificationText.redacted) else { return replyFallback }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    static func prompt(_ prompts: ChatPrompts) -> String? {
        if prompts.approvals.contains(where: { !$0.leaving }) { return "Review the command before it runs" }
        if let value = prompts.values.first(where: { !$0.late }) {
            switch value.kind {
            case .sudo: return "Administrator password needed"
            case .vaultCode: return "Enter your sign-in code"
            case .vaultUnlock: return "Unlock your password manager"
            case .vaultSaveLogin: return "Save a login to continue"
            default: return "Enter the requested credential"
            }
        }
        guard let ask = prompts.clarify else { return nil }
        guard let q = ask.questions.first(where: { !ask.lockedAnswers.keys.contains($0.qid) }), let choices = q.choices, choices.count > 1 else { return "Answer a question in chat" }
        if !q.multiSelect {
            let stem = q.question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for (prefix, action) in [("which branch", "Choose a branch"), ("which layout", "Choose a layout"), ("which header layout", "Choose a header layout"), ("which version", "Choose a version")] where stem.hasPrefix(prefix + " ") || stem == prefix + "?" {
                return action
            }
        }
        if !q.multiSelect, choices.count == 2 { return "Choose between two options" }
        return q.multiSelect ? "Select the options you want" : "Choose from \(choices.count) options"
    }
}

// MARK: - Mark All as Read (§5.6)

/// One chat whose `unread:false` write failed.
nonisolated struct SessionWriteFailure: Hashable, Sendable {
    var id: String
    var profile: String
    var reason: String

    /// The alert's reason (`filter-apply.ts:66`): the first failure's; with more than one, "<n> chats: <reason>".
    static func alertReason(_ failures: [SessionWriteFailure]) -> String {
        guard let first = failures.first else { return "" }
        return failures.count > 1 ? "\(failures.count) chats: \(first.reason)" : first.reason
    }
}

// MARK: - The reconnect probe (§11)

/// `sidebarProbeStats` (`S/sidebar-probe.ts:68-71`): limit-1 probes sent, full reads they saved, full reads made.
/// [perf-returns] `top`: short top-page reads made instead of a full read (docs/spec/3x-sessions.md §11.5).
nonisolated struct SidebarProbeStats: Hashable, Sendable {
    var probes = 0
    var skipped = 0
    var full = 0
    var top = 0

    var text: String { "probes=\(probes) skipped=\(skipped) full=\(full) top=\(top)" }
}

// MARK: - Session Info (§10.3)

/// A chat's usage as the gateway reports it (`AG/tui_gateway/contracts/common.py` Usage); every field optional, a value
/// that is not a finite number reads as absent.
nonisolated struct SessionUsage: Hashable, Sendable {
    var total: Int?
    var input: Int?
    var output: Int?
    var contextUsed: Int?
    var contextMax: Int?
    var contextPercent: Double?
    var contextEstimated: Bool?
    var costUsd: Double?
    // Tester 2026-10-27: the usage card. `input` is the uncached input only; `prompt` is everything sent
    // (input + cache reads + cache writes, H:agent/usage_pricing.py `CanonicalUsage.prompt_tokens`).
    var prompt: Int?
    var reasoning: Int?
    var calls: Int?
    var compressions: Int?
    /// Share of `prompt` read from the provider's cache, 0–100; absent when nothing was read from it.
    var cacheHitPercent: Double?
    /// Over the last ten calls (`avg_tps`, `avg_latency_s`); absent where the provider gives no timings (Codex).
    var tokensPerSecond: Double?
    var secondsPerCall: Double?

    /// nil unless an object.
    static func decode(_ json: JSONValue?) -> SessionUsage? {
        guard let o = json?.object else { return nil }
        func count(_ key: String) -> Int? {
            guard case .number(let n)? = o[key], n.isFinite, n >= 0 else { return nil }
            return Int(exactly: n.rounded(.towardZero))
        }
        func number(_ key: String) -> Double? {
            guard case .number(let n)? = o[key], n.isFinite else { return nil }
            return n
        }
        func positive(_ key: String) -> Double? { number(key).flatMap { $0 > 0 ? $0 : nil } }
        return SessionUsage(total: count("total"), input: count("input"), output: count("output"), contextUsed: count("context_used"),
                            contextMax: count("context_max"), contextPercent: number("context_percent"),
                            contextEstimated: o["context_estimated"]?.bool, costUsd: number("cost_usd"),
                            prompt: count("prompt"), reasoning: count("reasoning"), calls: count("calls"),
                            compressions: count("compressions"),
                            cacheHitPercent: number("cache_hit_pct").flatMap { $0 >= 0 ? Swift.min(100, $0) : nil },
                            tokensPerSecond: positive("avg_tps"), secondsPerCall: positive("avg_latency_s"))
    }
}

/// The gateway answered with another model (`S/phone-notices.ts:232-237`).
nonisolated struct ModelFallback: Hashable, Sendable {
    enum Category: String, Hashable, Sendable {
        case auth
        case billing
        case notFound
        case rateLimit
        case busy
        case timeout
        case other
    }

    var primary: String
    var fallback: String
    var reason: String?
    var primaryProvider: String? = nil
    var fallbackProvider: String? = nil
    var rawText: String = ""
    var retryAfterSeconds: Int? = nil
    var isProviderShape: Bool = false

    init(primary: String, fallback: String, reason: String? = nil,
         primaryProvider: String? = nil, fallbackProvider: String? = nil,
         rawText: String = "", retryAfterSeconds: Int? = nil, isProviderShape: Bool = false) {
        self.primary = primary
        self.fallback = fallback
        self.reason = reason
        self.primaryProvider = primaryProvider
        self.fallbackProvider = fallbackProvider
        self.rawText = rawText
        self.retryAfterSeconds = retryAfterSeconds
        self.isProviderShape = isProviderShape
    }

    private static let modelLead = JSRegex(#"Model fallback:\s*(\S+)\s+via\s+(\S+)\s+"#)
    private static let usingTail = JSRegex(#"^(\S+)(?:\s+via\s+(\S+?))?(?:\.(?:\s|$)|\s*$)"#)
    private static let retryIn = JSRegex(#"Primary retry eligible in\s*~?(\d+)\s*s\b"#)
    private static let provider = JSRegex(#"Provider fallback:\s*(\S+)\s+(?:unavailable|could not respond|failed)(?:\s+\(([\s\S]*)\))?;\s*using\s+(\S+?)(?:\s+for this response|\.(?:\s|$)|\s|$)"#)

    /// The gateway's status line, both shapes; nil for anything else.
    /// Splits on `; using ` first so reasons containing nested or truncated parentheses still parse cleanly.
    static func parse(_ text: String) -> ModelFallback? {
        if let modelRange = text.range(of: "Model fallback:", options: [.caseInsensitive]),
           let usingRange = text.range(of: "; using ", options: [.caseInsensitive], range: modelRange.upperBound..<text.endIndex) {
            let left = String(text[modelRange.lowerBound..<usingRange.lowerBound])
            let right = String(text[usingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let lead = modelLead.exec(left), lead.groups.count > 2,
               let tail = usingTail.exec(right), tail.groups.count > 1,
               !lead.groups[1].isEmpty, !tail.groups[1].isEmpty {
                let primary = lead.groups[1]
                let primaryProvider = lead.groups[2].isEmpty ? nil : lead.groups[2]
                let fallback = tail.groups[1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                let fallbackProviderRaw = tail.groups.count > 2 ? tail.groups[2].trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) : ""
                let fallbackProvider = fallbackProviderRaw.isEmpty ? nil : fallbackProviderRaw
                let afterLead = Range(lead.range, in: left)
                    .map { String(left[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let reason = extractReason(from: afterLead)
                let retry = retryIn.exec(right).flatMap { $0.groups.count > 1 ? Int($0.groups[1]) : nil }
                return ModelFallback(primary: primary, fallback: fallback, reason: reason,
                                     primaryProvider: primaryProvider, fallbackProvider: fallbackProvider,
                                     rawText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     retryAfterSeconds: retry, isProviderShape: false)
            }
        }
        if let groups = provider.exec(text)?.groups, groups.count > 3, !groups[1].isEmpty, !groups[3].isEmpty {
            let reason = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let retry = retryIn.exec(text).flatMap { $0.groups.count > 1 ? Int($0.groups[1]) : nil }
            return ModelFallback(primary: groups[1], fallback: groups[3].trimmingCharacters(in: CharacterSet(charactersIn: ".,;")),
                                 reason: reason.isEmpty ? nil : reason,
                                 primaryProvider: nil, fallbackProvider: nil,
                                 rawText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 retryAfterSeconds: retry, isProviderShape: true)
        }
        return nil
    }

    private static func extractReason(from statusAndReason: String) -> String? {
        guard let open = statusAndReason.firstIndex(of: "(") else { return nil }
        var inner = String(statusAndReason[statusAndReason.index(after: open)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasSuffix(")") {
            inner = String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inner.isEmpty ? nil : inner
    }

    /// "Primary model restored:" ends a fallback.
    static func restores(_ text: String) -> Bool { text.contains("Primary model restored:") }

    /// The model id named after "Primary model restored:"; empty string when none is named; nil for any other line.
    static func restoredModel(_ text: String) -> String? {
        guard let range = text.range(of: "Primary model restored:") else { return nil }
        let id = text[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return id.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }

    /// Classifies why the primary model failed so the timeline can separate actionable issues from transient blips.
    var category: Category {
        let lower = (reason ?? "").lowercased()
        if ["auth", "401", "403", "login", "oauth", "api key", "credential", "unauthorized", "setup-token"].contains(where: lower.contains) {
            return .auth
        }
        if ["billing", "quota", "credit", "insufficient", "402", "payment"].contains(where: lower.contains) {
            return .billing
        }
        if ["not found", "404", "unknown model", "does not exist", "invalid model", "unsupported"].contains(where: lower.contains) {
            return .notFound
        }
        if ["rate", "429", "too many requests", "limit"].contains(where: lower.contains) {
            return .rateLimit
        }
        if ["overload", "busy", "529", "503", "capacity"].contains(where: lower.contains) {
            return .busy
        }
        if ["timeout", "timed out", "server error", "500", "502", "504", "connection"].contains(where: lower.contains) {
            return .timeout
        }
        return .other
    }

    /// Persistent or user-fixable issues warrant a compact inline card; transient blips stay a quiet one-line pill.
    var isActionable: Bool {
        switch category {
        case .auth, .billing, .notFound: return true
        case .rateLimit, .busy, .timeout: return false
        case .other: return !extractedCommands.isEmpty
        }
    }

    /// An HTTP status code mentioned in the reason (e.g. "HTTP 401"), if any.
    var httpStatus: String? {
        guard let reason, let match = Self.httpCode.exec(reason), match.groups.count > 1, !match.groups[1].isEmpty else { return nil }
        return "HTTP \(match.groups[1])"
    }

    /// Complete CLI commands enclosed in backticks inside `reason` (skipping truncated `...` snippets).
    var extractedCommands: [String] {
        guard let reason, !reason.isEmpty else { return [] }
        var out: [String] = []
        var index = reason.startIndex
        while let open = reason[index...].firstIndex(of: "`") {
            let start = reason.index(after: open)
            guard let close = reason[start...].firstIndex(of: "`") else { break }
            let candidate = String(reason[start..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, !candidate.hasSuffix("..."), !candidate.hasSuffix("…"), !out.contains(candidate) {
                out.append(candidate)
            }
            index = reason.index(after: close)
        }
        return out
    }

    /// Environment variable names mentioned in the reason (e.g. `CLAUDE_CODE_OAUTH_TOKEN`).
    var mentionedEnvVars: [String] {
        guard let reason, !reason.isEmpty else { return [] }
        let regex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9_]{4,}\b"#)
        let range = NSRange(reason.startIndex..., in: reason)
        var out: [String] = []
        for match in regex?.matches(in: reason, range: range) ?? [] {
            guard let swiftRange = Range(match.range, in: reason) else { continue }
            let token = String(reason[swiftRange])
            if token.contains("_"), !out.contains(token) { out.append(token) }
        }
        return out
    }

    private static let httpCode = JSRegex(#"\bHTTP\s+(\d{3})\b"#)
}
