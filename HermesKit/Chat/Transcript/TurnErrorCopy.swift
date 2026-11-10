// [transcript] A failed turn in words (docs/spec/3x-transcript.md §6.1 and §6.2, rows L352 and L353). Ported from
// `S/phone-notices.ts` (turnErrorCopy, noticeDetailClosed, turnErrorResetsAt), `S/fe-convo-r6.ts` (withoutRetryWords),
// `S/fe-convo-r5.ts` (detailRepeatsBody, withoutRetryHint, the session banner's titles) and `S/fe-convo-r1.ts`
// (withoutDuplicateTurnErrors).

import Foundation

nonisolated enum TurnErrorKind: String, Sendable {
    case usageLimit, anotherWindow, modelStart, gatewayBusy, cutOff
    // [recovery] Plain-words provider failures (n20 ec0a3896's error texts; no separate Switch Provider button here —
    // these reuse the card's existing Choose a Model button, docs/spec/3x-transcript.md §6.1).
    case billing, badApiKey, providerDown, modelGone
}

nonisolated struct TurnErrorCopy: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case retry, chooseModel, newChat }
    var kind: TurnErrorKind
    var title: String
    var body: String
    var primary: Primary
    var resetsAt: TimeInterval?
}

nonisolated enum TurnErrors {
    static let limit = TRx(#"\b429\b|usage[_ ]limit|rate[_ ]?limit|quota (?:is )?(?:exhausted|exceeded)|too many requests"#, [.caseInsensitive])
    static let owned = TRx(#"open in another Hermes window|another live owner|SESSION_NOT_OWNED|session has another"#, [.caseInsensitive])
    /// `4090 SESSION_OWNER_BUSY`'s words (tui_gateway/methods_prompt.py `_submit_to_ledger_owner`).
    /// [locked-chat] A busy refusal whose hand-off to the gateway's queue was refused too (`_submit_to_ledger_owner`).
    static let handOffRefused = TRx(#"running a turn in this chat and the gateway refused it"#, [.caseInsensitive])
    static let ownerBusy = TRx(#"send it again when the current turn ends|SESSION_OWNER_BUSY"#, [.caseInsensitive])
    static let start = TRx(#"could not start the assistant|couldn['’]t start (?:the )?(?:assistant|agent|model)|agent[_ ]init|failed to (?:initiali[sz]e|start) (?:the )?agent|could not find the '[^']+' CLI command"#, [.caseInsensitive])
    static let busy = TRx(#"readiness probe|exceeded its budget|\b5097\b"#, [.caseInsensitive])
    /// What the app itself writes when the link drops under a reply (`LiveChatSession`), and what a gateway says.
    static let cut = TRx(#"connection (?:was )?(?:lost|dropped|closed)|reply was cut off|stream (?:ended|closed) (?:early|before)|socket closed|disconnected (?:before|while)"#, [.caseInsensitive])
    /// A provider's HTTP status the way error texts carry one ("Error code: 529 - …", "status 402", "HTTP 404", "(401)"),
    /// not a bare number, which could be anything (a line number, a token count, a page a tool fetched).
    private static func status(_ code: String) -> String {
        #"(?:error code|status(?: code)?|http)\s*:?\s*"# + code + #"\b|\("# + code + #"\)"#
    }
    /// Low or no credit with the provider ("Anthropic: your credit balance is too low (402).", n20 ec0a3896's sample).
    static let billing = TRx(#"credit balance|\bbilling\b|insufficient[_ ]credits?|"# + status("402"), [.caseInsensitive])
    /// A bad or missing key, or a refused sign-in ("Anthropic rejected the API key (401)."); 403 too (a provider's own,
    /// not the gateway's maintenance refusals, which never reach this card).
    static let badApiKey = TRx(#"invalid[_ ]?(?:x-)?api[_ ]?key|rejected the api key|authentication[_ ](?:error|failed)|"# + status("40[13]"),
                               [.caseInsensitive])
    /// The provider itself is down or overloaded ("Overloaded", "HTTP 529", "503 Service Unavailable"), not Hermes's
    /// own gateway (`busy`, above).
    static let providerDown = TRx(#"overloaded|service unavailable|bad gateway|internal server error|gateway time-?out|"# + status(#"5\d\d"#),
                                  [.caseInsensitive])
    /// The part of `providerDown` that really is a busy provider ("Overloaded", 529, 503): only these are called
    /// overloaded. Any other server error (500, 502, 504, "internal server error") is a problem at the provider.
    static let overloaded = TRx(#"overloaded|service unavailable|"# + status("5(?:29|03)"), [.caseInsensitive])
    /// The model itself no longer exists ("The model 'x' does not exist (404)."): another try would fail the same way.
    static let modelGone = TRx(#"model_not_found|\bmodel\b[^\n]{0,60}?\b(?:does not exist|not found)|"# + status("404"), [.caseInsensitive])
    private static let resetsAtRE = TRx(#"resets?_at["'\s:=]+(\d{10})\b"#, [.caseInsensitive])
    private static let waits = [
        TRx(#"retry after\s+(\d+(?:\.\d+)?)\s*s"#, [.caseInsensitive]),
        TRx(#"resets?_in_seconds["'\s:=]+(\d+)"#, [.caseInsensitive]),
        TRx(#"retry-after["'\s:=]+(\d+)"#, [.caseInsensitive]),
        TRx(#"resets? in\s+(\d+)\s*s(?:ec(?:ond)?s?)?\b"#, [.caseInsensitive]),
    ]
    private static let provider = TRx(#"\b([A-Z][\w-]*|openai-codex|codex|anthropic|openai)\b provider (?:quota|rate)"#, [.caseInsensitive])
    static let cutOffTitle = "The reply was cut off"

    /// When the provider's limit lifts (unix seconds), from the wait the error text names.
    static func resetsAt(_ text: String, now: Date) -> TimeInterval? {
        if let groups = resetsAtRE.groups(text), let at = groups[1].flatMap(Double.init) { return at }
        for pattern in waits {
            if let groups = pattern.groups(text), let wait = groups[1].flatMap(Double.init) {
                return (now.timeIntervalSince1970 + wait).rounded()
            }
        }
        return nil
    }

    /// "3:10 PM" today, "Sat, Oct 3, 12:57 PM" on another day.
    static func resetTimeLabel(_ resetsAt: TimeInterval, now: Date, locale: Locale = .autoupdatingCurrent,
                               timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let when = Date(timeIntervalSince1970: resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(when, inSameDayAs: now) ? "jmm" : "EEEMMMdjmm")
        return formatter.string(from: when)
    }

    /// A provider failure whose title may gain " until <time>" and whose body may offer a wait instead of its usual
    /// words, when the text gives a reset (the usage limit kind's own shape, §6.1).
    private static func providerCopy(_ kind: TurnErrorKind, title: String, otherwise: String, text: String, now: Date,
                                     at: Date?, locale: Locale, timeZone: TimeZone) -> TurnErrorCopy {
        let resets = resetsAt(text, now: at ?? now)
        let reset = resets.flatMap { $0 > now.timeIntervalSince1970 ? resetTimeLabel($0, now: now, locale: locale, timeZone: timeZone) : nil } ?? ""
        return TurnErrorCopy(kind: kind, title: reset.isEmpty ? title : "\(title) until \(reset)",
                             body: reset.isEmpty ? otherwise : "Choose another model, or wait until then.",
                             primary: .chooseModel, resetsAt: resets)
    }

    /// The failure's words when it is one of the known kinds; nil for anything else (the card keeps its own title).
    /// `at`: when the failure happened (a relative wait counts from it). Precedence as on the web: open elsewhere,
    /// usage limit, then the plain-words provider failures (billing, a bad key, the provider down, a gone model —
    /// after usage limit, so a provider's own words in a usage-limit text don't steal it), model start, gateway busy;
    /// then the cut-off reply.
    static func copy(_ text: String, now: Date = Date(), at: Date? = nil, locale: Locale = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> TurnErrorCopy? {
        if owned.test(text) {
            return TurnErrorCopy(kind: .anotherWindow, title: "This chat is open somewhere else",
                                 body: "\(HostWord.sentence), or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and try again.",
                                 primary: .newChat)
        }
        if limit.test(text) {
            let resets = resetsAt(text, now: at ?? now)
            let name = provider.groups(text)?[1] ?? nil
            let reset = resets.flatMap { $0 > now.timeIntervalSince1970 ? resetTimeLabel($0, now: now, locale: locale, timeZone: timeZone) : nil } ?? ""
            let who = name.map { "\($0.prefix(1).uppercased())\($0.dropFirst()) usage limit" } ?? "Usage limit"
            return TurnErrorCopy(kind: .usageLimit, title: "\(who) reached\(reset.isEmpty ? "" : " until \(reset)")",
                                 body: reset.isEmpty ? "Choose another model, or try again later." : "Choose another model, or wait until then.",
                                 primary: .chooseModel, resetsAt: resets)
        }
        if billing.test(text) {
            return providerCopy(.billing, title: "Low on credit", otherwise: "Choose another model, or add credit with its provider.",
                                text: text, now: now, at: at, locale: locale, timeZone: timeZone)
        }
        if badApiKey.test(text) {
            return providerCopy(.badApiKey, title: "This model’s API key failed", otherwise: "Choose another model, or fix the API key with its provider.",
                                text: text, now: now, at: at, locale: locale, timeZone: timeZone)
        }
        if providerDown.test(text) {
            // A retry can genuinely work here (the outage is usually brief), so the body still names it, even though
            // the card's one button stays "Choose a Model" (decision: no separate Switch Provider button).
            let title = overloaded.test(text) ? "This model’s provider is overloaded" : "This model’s provider had a problem"
            return providerCopy(.providerDown, title: title, otherwise: "Choose another model, or try again in a moment.",
                                text: text, now: now, at: at, locale: locale, timeZone: timeZone)
        }
        if modelGone.test(text) {
            // Gone for good: no reset, and a retry would just fail the same way again.
            return TurnErrorCopy(kind: .modelGone, title: "This model is gone",
                                 body: "Choose another model to continue this chat.", primary: .chooseModel)
        }
        if start.test(text) {
            return TurnErrorCopy(kind: .modelStart, title: "This chat’s model couldn’t start",
                                 body: "\(HostWord.sentence) couldn’t start this chat’s model. Choose another model, or check the model’s provider there.",
                                 primary: .chooseModel)
        }
        if busy.test(text) {
            return TurnErrorCopy(kind: .gatewayBusy, title: "\(HostWord.sentence) is busy",   // UX study #24
                                 body: "It didn’t answer in time while it checked its model. Try again in a moment.", primary: .retry)
        }
        if cut.test(text) {
            return TurnErrorCopy(kind: .cutOff, title: cutOffTitle,
                                 body: "The connection dropped before the reply finished. \(DeviceWord.Tap) Try Again to send it again.", primary: .retry)
        }
        return nil
    }

    /// A provider or quota failure's Details start closed: the card's words already say what happened.
    static func detailClosed(_ detail: String?) -> Bool {
        guard let detail, !detail.isEmpty else { return false }
        return limit.test(detail) || start.test(detail) || billing.test(detail) || badApiKey.test(detail)
            || providerDown.test(detail) || modelGone.test(detail)
    }

    // MARK: Details that only repeat the card (r5-95)

    private static let marks = TRx(#"[`*_]"#)
    private static let trailing = TRx(#"[.\s]+$"#)
    private static let spaces = TRx(#"\s+"#)

    private static func squash(_ text: String) -> String {
        spaces.replace(trailing.replace(marks.replace(text.lowercased(), with: ""), with: ""), with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func detailRepeatsBody(_ detail: String, _ shown: String?...) -> Bool {
        let text = squash(detail)
        if text.isEmpty { return true }
        return shown.contains { line in
            guard let line, !line.isEmpty else { return false }
            let s = squash(line)
            return s == text || s.hasPrefix(text)
        }
    }

    // MARK: No retry words without a Retry button (r6-01)

    private static let retryAlone = TRx(#"^(?:tap\s+)?(?:retry|try again)(?:\s+(?:to|and)\b[^.]*)?\.?$"#, [.caseInsensitive])
    private static let retryOr = TRx(#"^(?:retry|try again),?\s+or\s+(.+)$"#, [.caseInsensitive])
    private static let moment = TRx(#"^(?:retry|try again)\s+in\s+a\s+moment(?:,?\s+or\s+(.+?))?\.?$"#, [.caseInsensitive])
    private static let later = TRx(#"^(?:retry|try again)\s+later\.?$"#, [.caseInsensitive])
    private static let thenRetry = TRx(#",?\s*then\s+retry\b"#, [.caseInsensitive])
    private static let tryAgain = TRx(#"\btry\s+again\b"#, [.caseInsensitive])
    private static let leadRetry = TRx(#"^retry\b"#, [.caseInsensitive])
    private static let sentenceEnd = TRx(#"(?<=[.!?])\s+"#)
    private static let retryHint = TRx(#"\s*(?:Tap Try Again|Retry)(?: to| and)? [^.]*\.?\s*$"#)

    private static func cap(_ text: String) -> String { text.isEmpty ? text : text.prefix(1).uppercased() + text.dropFirst() }
    private static func period(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }

    private static func withoutRetrySentence(_ sentence: String) -> String? {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        if retryAlone.test(text) { return nil }
        if let groups = retryOr.groups(text), let rest = groups[1] { return period(cap(rest.trimmingCharacters(in: .whitespaces))) }
        if let groups = moment.groups(text) {
            if let rest = groups[1], !rest.isEmpty { return "\(cap(rest.trimmingCharacters(in: .whitespaces))), or send it again in a moment." }
            return "Send it again in a moment."
        }
        if later.test(text) { return "Send it again later." }
        var out = thenRetry.replace(text, with: ", then send it again")
        out = tryAgain.replace(out, with: "send it again")
        out = leadRetry.replace(out, with: "Send it again")
        return out
    }

    /// The card's body when it offers no Retry: sentence by sentence, without retry wording.
    static func withoutRetryWords(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split after sentence punctuation followed by whitespace.
        let marked = sentenceEnd.replace(trimmed, with: "\u{1}")
        let kept = marked.split(separator: "\u{1}").map(String.init).compactMap(withoutRetrySentence)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let out = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? body : out
    }

    /// The card's body without the sentence that points at Retry.
    static func withoutRetryHint(_ body: String) -> String {
        let out = retryHint.replace(body, with: "").trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? body : out
    }

    // MARK: One card per failed turn (r1-37)

    static func sameFailure(_ a: String, _ b: String) -> Bool {
        if a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        guard let ka = copy(a)?.kind, let kb = copy(b)?.kind else { return false }
        return ka == kb
    }

    private static func shows(_ message: ChatMessage) -> Bool {
        message.parts.contains { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }

    /// A failed submit and the stream's own error for the same turn each made a card with the same failure: the turn
    /// keeps one (the one with output, else the latest). The others keep their place with their error cleared (they
    /// then draw nothing), so the array's positions do not move.
    static func withoutDuplicateTurnErrors(_ messages: [ChatMessage]) -> [ChatMessage] {
        let lastUser = messages.lastIndex { $0.role == .user && $0.sender == nil } ?? -1
        let failed = messages.indices.filter { $0 > lastUser && messages[$0].role == .assistant && messages[$0].error != nil }
        guard failed.count >= 2 else { return messages }
        var drop: Set<Int> = []
        for index in failed {
            let message = messages[index]
            if shows(message) { continue }
            let twin = failed.first { other in
                other != index && !drop.contains(other) && sameFailure(messages[other].error ?? "", message.error ?? "")
                    && (shows(messages[other]) || other > index)
            }
            if twin != nil { drop.insert(index) }
        }
        guard !drop.isEmpty else { return messages }
        var out = messages
        for index in drop { out[index].error = nil }
        return out
    }

    // MARK: The session problem (r5-92)

    private static let cancelled = TRx(#"^(?:Turn cancelled|Session no longer running) before the agent was ready"#, [.caseInsensitive])
    private static let reopen = TRx(#"could not reopen that session"#, [.caseInsensitive])

    /// A session-level error the chat does not report (a turn cancelled before the agent was ready).
    static func isIgnoredSessionError(_ text: String) -> Bool {
        cancelled.test(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isReopenFailure(_ text: String) -> Bool { reopen.test(text) }
}

/// A problem with the chat itself (no turn in flight): the card docked above the composer (§6.2).
nonisolated struct SessionProblem: Equatable, Sendable {
    enum Primary: Equatable, Sendable { case chooseModel, tryAgain, newChat }
    var title: String
    var body: String
    /// The raw text, for Copy (and "More").
    var detail: String
    var primary: Primary

    /// The chat could not be reopened (§6.5): a resume that lands clears it.
    var reopen: Bool { title == "Couldn’t reopen this chat" }

    /// What Copy puts on the pasteboard.
    var copyText: String {
        [title, body, detail == body ? "" : detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The card for an `error` event that arrived with no turn running; nil for the ones the chat ignores.
    /// `botName`: "Hermes reported a problem" names the chat's bot. `room`: a group room has no single model to choose.
    static func make(text: String, botName: String, room: Bool = false, now: Date = Date()) -> SessionProblem? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !TurnErrors.isIgnoredSessionError(raw) else { return nil }
        let known = TurnErrors.copy(raw, now: now)
        let bot = botName.trimmingCharacters(in: .whitespaces)
        let title = known?.title ?? (TurnErrors.isReopenFailure(raw) ? "Couldn’t reopen this chat"
                                     : "\(bot.isEmpty ? "Hermes" : bot) reported a problem")
        let short = raw.count <= 240 && !raw.contains(where: \.isNewline)
        let body = known?.body ?? (short ? raw : "Something went wrong with this chat. Copy the details if it keeps happening.")
        let choose = !room && (known?.kind == .usageLimit || known?.kind == .modelStart)
        return SessionProblem(title: title, body: body, detail: raw, primary: choose ? .chooseModel : .tryAgain)
    }

    /// [locked-chat] The gateway won't open this chat any more (`LiveChatSession.isChatLocked`): nothing sent here can
    /// reach the bot, so the card's one action is a new chat with the same bot, the words carried over.
    static let chatLockedTitle = "This chat can’t take messages"
    static func chatLocked(detail: String) -> SessionProblem {
        SessionProblem(title: chatLockedTitle,
                       body: "Hermes won’t open this chat any more, so messages sent here can’t reach it. Your message is still in the box below. Continue in a new chat with the same bot.",
                       detail: detail, primary: .newChat)
    }

    /// A cold bot that never came up (§6.5): both resume attempts failed or timed out.
    static func reopenFailed(starting: Bool) -> SessionProblem {
        let body = starting ? "This chat is still starting on \(HostWord.phrase)." : "\(HostWord.sentence) didn’t answer in time."
        return SessionProblem(title: "Couldn’t reopen this chat", body: body, detail: body, primary: .tryAgain)
    }
}

/// A send the gateway refused, or that never left (§6.3): the "Couldn’t Send" card at the composer.
nonisolated struct SendFailure: Equatable, Sendable {
    var reason: String
    var timedOut: Bool
    var offline: Bool
    var at: Date

    static let title = "Couldn’t Send"

    var body: String {
        if timedOut { return "\(HostWord.sentence) didn’t answer in time. Your message is still in the box below." }
        if offline { return "You’re offline. Your message is still in the box below." }
        // 4090 SESSION_NOT_OWNED: the gateway's "another Hermes window/terminal" is often this phone's own earlier
        // connection (it opens chats as "desktop"), so the card says it plainly; the Details line is behind Copy.
        if TurnErrors.owned.test(reason) {
            return "Your message is still in the box below. Hermes has this chat open somewhere else, like the Hermes desktop app. Close it there and try again, or start a new chat."
        }
        // 4090 SESSION_OWNER_BUSY: the gateway's own words name "the gateway" twice and an internal queue (build 337).
        if TurnErrors.ownerBusy.test(reason) {
            return "Your message is still in the box below. Hermes is still running a reply in this chat. Send it again when that reply is done."
        }
        let words = SendFailure.oneSentence(reason)
        return words.isEmpty ? "Your message is still in the box below." : "Your message is still in the box below. \(words)"
    }

    /// The gateway's whole refusal, for the card's Copy, when it carries a `Details:` line (who holds the chat, and
    /// since when: hermes_cli/active_sessions.py) that the one-sentence body leaves out.
    var copyText: String? {
        reason.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Details:") }
            ? reason : nil
    }

    /// The gateway's message as one sentence, at most 160 characters.
    static func oneSentence(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = text.split(whereSeparator: \.isNewline).first { text = String(line) }
        if text.count > 160 { text = String(text.prefix(159)).trimmingCharacters(in: .whitespaces) + "…" }
        guard let first = text.first else { return "" }
        text = first.uppercased() + text.dropFirst()
        if let last = text.last, !".!?…".contains(last) { text += "." }
        return text
    }

    static func make(reason: String?, now: Date = Date()) -> SendFailure {
        let raw = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let timedOut = lower.contains("timed out") || lower.contains("timeout") || lower.contains("didn’t answer in time")
            || lower.contains("didn't answer in time")
        let offline = lower.hasPrefix("you’re offline") || lower.hasPrefix("you're offline") || lower.contains("internet connection appears to be offline")
            || lower.contains("not connected to the internet")
        return SendFailure(reason: raw, timedOut: timedOut, offline: offline && !timedOut, at: now)
    }
}
