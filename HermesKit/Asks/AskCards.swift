// [asks] A bot asks before it acts for you (the add-on's `ask_to_act`): someone wrote to you ("Dana asked if we
// start with the pilot group"), and the bot wants your one-word answer before it drafts the reply. It is drawn in
// the chat as a card: where it came from, their words, what they attached, a link to the place, the question, a
// button per choice (the first is the bot's pick), "Something else…" and what the bot does next. The tool sends
// nothing and doesn't wait: the card is the tool call, and your answer goes back as an ordinary message whose first
// line names the card:
//
//     [Hermes HQ ask a-1a2b3c4d: 1]
//     Yes.
//     (Your question was: "Start with the pilot group?" Go on as you said: I'll draft the reply. Nothing gets sent.)
//
//     [Hermes HQ ask a-1a2b3c4d: other]
//     Only the two team leads first.
//     (Your question was: "Start with the pilot group?")
//
// [asks v2] When the bot already knows what it would write for a choice it passes that reply (`replies`, one per
// choice, and `reply_to`: where they go). Tapping such a choice only picks it (nothing is sent): the card shows the
// reply with Send and Edit, and Send answers with the choice and the reply together, so the bot sends it without
// another round:
//
//     [Hermes HQ ask a-1a2b3c4d: 1 send]
//     Yes. Send this to Dana Reyes (Slack) exactly as written:
//
//     <the reply, your edits included>
//
// Everything here reads the transcript alone, so a card shows the same state after a relaunch and on another device:
// answered once a later message of yours names it. The id is made from the call's own words (the add-on makes the
// same one), so nothing depends on the tool's result. Parsing is lenient: the add-on checks strictly and tells the
// model what to fix; here a wrong value is left out, and only a call without a question is not a card.

import CryptoKit
import Foundation
import os

nonisolated enum AskCards {
    static let tool = "ask_to_act"
    /// Its arguments are kept whole up to this size (a 2,000-character quote and four attachments run past the 4 KB
    /// every other call keeps, `ToolArgs.maxBytes`): the card draws them.
    static let maxArgsBytes = 64_000
    static let defaultChoices = ["Yes", "No"]
    static let maxChoices = 3, maxAttachments = 4

    struct Attachment: Hashable, Sendable {
        var name: String
        var note: String
    }

    struct Link: Hashable, Sendable {
        var title: String
        var url: URL
    }

    struct Ask: Hashable, Sendable {
        var id: String
        var question: String
        /// What the bot does once you answer ("I'll draft the reply. Nothing gets sent."). May be empty.
        var then: String
        /// Two or three; the first is the bot's pick.
        var choices: [String]
        var app: String = ""
        var from: String = ""
        var place: String = ""
        var when: String = ""
        var quote: String = ""
        var attachments: [Attachment] = []
        var link: Link? = nil
        /// [asks v2] The reply the bot would write for each choice (`replies`, one per choice, "" for none); empty when
        /// the bot gave none, or a list that doesn't match the choices.
        var replies: [String] = []
        /// Where those replies go (`reply_to`); nil without replies.
        var replyTo: ReplyTo? = nil
        /// Optional 0-based index of the bot's recommended choice (explicit `"recommended"` field or trailing
        /// `"(Recommended)"` on a choice). Nil when the choices are neutral peers.
        var recommended: Int? = nil
        /// Optional one-line rationale displayed quietly under the recommended choice.
        var why: String = ""

        /// True when the ask came from an external channel / person / link and should show the Grok-style source header.
        var hasExternalSource: Bool {
            !app.isEmpty || !from.isEmpty || !place.isEmpty || !when.isEmpty || link != nil
        }
    }

    /// [asks v2] Where a choice's ready reply goes: the app, and who, about what, from which account.
    struct ReplyTo: Hashable, Sendable {
        var app: String
        var to: String = ""
        var subject: String = ""
        var from: String = ""
    }

    enum DeliveryState: Hashable, Sendable {
        case sent
        case sending
        case queued
        case failed
    }

    struct RowAnswer: Hashable, Sendable {
        var answer: Answer
        var delivery: DeliveryState
    }

    enum Answer: Hashable, Sendable {
        /// The choice's 1-based number, and the words its message carries.
        case choice(Int, String)
        /// What you typed under "Something else…".
        case other(String)
        /// [asks v2] A choice with its ready reply approved to send (`: N send`): the choice's words and the reply that
        /// went, your edits included (empty when the message carried none).
        case sent(Int, String, reply: String)

        var isOther: Bool {
            if case .other = self { return true }
            return false
        }
    }

    // MARK: The add-on

    /// PUT here (under the add-on's route) says an app that draws ask cards uses this computer; until then the add-on
    /// keeps `ask_to_act` from its bots, so a question is never left where nobody sees a card.
    static let cardsPath = "/asks/cards"

    /// The add-on has `ask_to_act` (`actCards`) and hasn't heard from such an app (`actCardsShown`). Not `askCards`:
    /// that older flag is the add-on's clarify note (ask_cards.py, 0.9.12).
    static func cardsUntold(_ status: [String: Any]?) -> Bool {
        (status?["actCards"] as? NSNumber)?.boolValue == true && (status?["actCardsShown"] as? NSNumber)?.boolValue != true
    }

    // MARK: The call

    /// An ask call's arguments as text, whole; nil for any other tool or one too big to keep.
    static func wholeArgsText(name: String, args: [String: JSONValue]) -> String? {
        guard name == tool, !args.isEmpty else { return nil }
        let text = ChatJSON.stringify(.object(args))
        return text.utf8.count <= maxArgsBytes ? text : nil
    }

    private static let parseCache = OSAllocatedUnfairLock(initialState: [String: Ask?]())

    /// The ask a tool call holds; nil when it isn't one, it failed, its arguments aren't whole (a cached transcript
    /// cut them: it then draws as the plain step it is) or it has no question.
    static func parse(_ call: ToolCall) -> Ask? {
        guard call.name == tool, call.state != .failed, let text = call.argsText else { return nil }
        if let hit = parseCache.withLock({ $0[text] }) { return hit }
        let parsed = ChatJSON.parse(string: text)?.object.flatMap(parse(_:))
        parseCache.withLock { cache in
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[text] = parsed
        }
        return parsed
    }

    /// Choice label cleaned for display (removes a trailing `"(Recommended)"` tag since the pill draws it).
    static func choiceTitle(_ choice: String) -> String { ClarifyText.bareChoice(choice) }

    static func parse(_ o: [String: JSONValue]) -> Ask? {
        let question = trimmed(o["question"])
        guard !question.isEmpty else { return nil }
        let from = trimmed(o["from"]), quote = trimmed(o["quote"])
        let choices = choices(o["choices"])
        var ask = Ask(id: id(question: question, from: from, quote: quote, choices: choices), question: question,
                      then: trimmed(o["then"]), choices: choices)
        ask.app = line(o["app"], 40)
        ask.from = line(o["from"], 120)
        ask.place = line(o["where"], 120)
        ask.when = line(o["when"], 60)
        ask.quote = quote
        ask.why = line(o["why"], 200)
        ask.recommended = parseRecommended(o["recommended"], choices: choices)
        ask.attachments = (o["attachments"]?.array ?? []).compactMap { value -> Attachment? in
            if let a = value.object {
                let name = line(a["name"], 80)
                return name.isEmpty ? nil : Attachment(name: name, note: line(a["note"], 160))
            }
            let name = line(value, 80)
            return name.isEmpty ? nil : Attachment(name: name, note: "")
        }.prefix(maxAttachments).map { $0 }
        if let l = o["link"]?.object, let url = https(trimmed(l["url"])) {
            let title = line(l["title"], 60)
            ask.link = Link(title: title.isEmpty ? defaultLinkTitle(ask.app) : title, url: url)
        }
        readReplies(o, into: &ask)
        return ask
    }

    private static func parseRecommended(_ value: JSONValue?, choices: [String]) -> Int? {
        if let n = value?.int, choices.indices.contains(n) { return n }
        if case .bool(true)? = value, !choices.isEmpty { return 0 }
        if let label = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let needle = ClarifyText.bareChoice(label).lowercased()
            if let idx = choices.firstIndex(where: { ClarifyText.bareChoice($0).lowercased() == needle }) { return idx }
        }
        if let idx = choices.firstIndex(where: ClarifyText.isRecommended) { return idx }
        return nil
    }

    /// [asks v2] Each reply may run this long (the add-on's own limit).
    static let maxReply = 20_000

    /// [asks v2] `replies` and `reply_to`: kept only when there is one reply per choice, at least one isn't blank and
    /// there is an app to send them on (`reply_to.app`, else the ask's own app). A reply past the limit is left out.
    private static func readReplies(_ o: [String: JSONValue], into ask: inout Ask) {
        guard let items = o["replies"]?.array, items.count == ask.choices.count else { return }
        let replies = items.map { item -> String in
            let words = trimmed(item)
            return words.count <= maxReply ? words : ""
        }
        guard replies.contains(where: { !$0.isEmpty }) else { return }
        let r = o["reply_to"]?.object ?? [:]
        var app = line(r["app"], 40)
        if app.isEmpty { app = ask.app }
        guard !app.isEmpty else { return }
        ask.replies = replies
        ask.replyTo = ReplyTo(app: app, to: line(r["to"], 300), subject: line(r["subject"], 300), from: line(r["from"], 300))
    }

    /// [asks v2] The ready reply for a choice (0-based); nil when it has none (a tap answers at once).
    static func reply(_ ask: Ask, index: Int) -> String? {
        guard ask.replyTo != nil, ask.replies.indices.contains(index), !ask.replies[index].isEmpty else { return nil }
        return ask.replies[index]
    }

    /// The bot's choices: two or three distinct words (trimmed, blanks left out); anything else is Yes / No.
    static func choices(_ value: JSONValue?) -> [String] {
        var out: [String] = []
        for item in value?.array ?? [] {
            let words = trimmed(item)
            if !words.isEmpty, !out.contains(words) { out.append(words) }
        }
        return out.count >= 2 ? Array(out.prefix(maxChoices)) : defaultChoices
    }

    static func defaultLinkTitle(_ app: String) -> String { app.isEmpty ? "Open" : "Open in \(app)" }

    /// "a-" and the first 8 hex digits of SHA-256 over `question\nfrom\nquote\n` and the choices joined by newlines
    /// (each trimmed; Yes / No when the bot gave none), as the add-on's own.
    static func id(question: String, from: String, quote: String, choices: [String]) -> String {
        let parts = [question, from, quote] + choices
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        return "a-" + SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func trimmed(_ value: JSONValue?) -> String {
        (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of at most `max` characters (line breaks become spaces).
    private static func line(_ value: JSONValue?, _ max: Int) -> String {
        let text = trimmed(value).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return text.count <= max ? text : String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func https(_ text: String) -> URL? {
        guard text.lowercased().hasPrefix("https://"), let url = URL(string: text), url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Words

    /// The round mark beside the source line: an envelope for mail, a bubble for a chat app, a question mark else.
    static func glyph(_ ask: Ask) -> String {
        let kind = ask.app.lowercased()
        if kind.isEmpty { return "questionmark.circle.fill" }
        if ["mail", "gmail", "outlook"].contains(where: kind.contains) { return "envelope.circle.fill" }
        if ["slack", "telegram", "discord", "message", "text", "whatsapp", "sms", "signal", "teams", "chat"].contains(where: kind.contains) {
            return "bubble.left.circle.fill"
        }
        return "questionmark.circle.fill"
    }

    /// [calm-chat] Quiet outline glyph for a folded stale ask disclosure row.
    static func quietGlyph(_ ask: Ask) -> String {
        let kind = ask.app.lowercased()
        if kind.isEmpty { return "questionmark.circle" }
        if ["mail", "gmail", "outlook"].contains(where: kind.contains) { return "envelope" }
        if ["slack", "telegram", "discord", "message", "text", "whatsapp", "sms", "signal", "teams", "chat"].contains(where: kind.contains) {
            return "bubble.left"
        }
        return "questionmark.circle"
    }

    /// [calm-chat] Row id for an `ask_to_act` tool call, matching `PromptRows.askRow`.
    static func rowId(messageId: String, callId: String) -> String { "\(messageId)|ask\(callId)" }

    /// [calm-chat] Ask row ids left unanswered after a later normal human turn (voice memo, typed follow-up, phone
    /// call result) or a later ask card in a subsequent message. Sibling asks in the same message stay live while
    /// another sibling is answered via button tap.
    static func staleRowIds(_ messages: [ChatMessage]) -> Set<String> {
        var lastHumanOrAsk = -1
        for (idx, m) in messages.enumerated() {
            if DraftCards.isNormalHumanTurn(m) {
                lastHumanOrAsk = idx
            } else if m.role == .assistant, m.parts.contains(where: { part in
                guard case .tool(let c) = part, c.name == tool else { return false }
                return parse(c) != nil
            }) {
                lastHumanOrAsk = idx
            }
        }
        guard lastHumanOrAsk > 0 else { return [] }
        var out = Set<String>()
        for (idx, m) in messages.enumerated() where idx < lastHumanOrAsk && m.role == .assistant {
            for part in m.parts {
                guard case .tool(let c) = part, c.name == tool, parse(c) != nil else { continue }
                out.insert(rowId(messageId: m.id, callId: c.id))
            }
        }
        return out
    }

    /// [calm-chat] Whether `messages[index]` is a synthetic ask-card tap immediately answering an ask card in the
    /// preceding non-system assistant message (so the card right above already shows the settled choice).
    static func isAdjacentAnswerEcho(_ messages: [ChatMessage], at index: Int, askId: String) -> Bool {
        var scan = index - 1
        while scan >= 0 {
            let prev = messages[scan]
            if prev.role == .system { scan -= 1; continue }
            guard prev.role == .assistant else { return false }
            return prev.parts.contains { part in
                guard case .tool(let c) = part, c.name == tool, let a = parse(c) else { return false }
                return a.id == askId
            }
        }
        return false
    }

    private static let readyBoilerplate = TRx(
        #"^(?:(?:the|your)\s+(?:approval|decision|ask|action|confirmation)\s+card\s+is\s+ready(?:\s+(?:above|below|for\s+review|to\s+review))?[.!]?|waiting\s+(?:on\s+you|for\s+your\s+(?:approval|answer|reply|call|confirmation))[.!]?|let\s+me\s+know\s+(?:how\s+you(?:['’]d|\s+would)\s+like\s+to\s+proceed|what\s+you(?:['’]d|\s+would)\s+like\s+(?:me\s+)?to\s+do)[.!]?)$"#
    )

    /// [calm-chat] True only when an assistant message's entire prose alongside an ask card is pure card-ready chrome
    /// carrying no additional context.
    static func isReadyBoilerplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 90, !trimmed.contains(where: \.isNewline),
              !trimmed.contains("http://"), !trimmed.contains("https://"), !trimmed.contains("`") else { return false }
        let collapsed = trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return readyBoilerplate.groups(collapsed) != nil
    }

    /// [calm-chat] Lookback for `ChatRowModel.rebuildNewest`: when `messages[from...]` adds an ask, an ask answer,
    /// or a normal human turn, reach back to earlier ask cards at or after `floor` so they fold live.
    static func reach(from: Int, floor: Int, in messages: [ChatMessage]) -> Int {
        guard from > floor, from < messages.count else { return from }
        var triggers = false
        for m in messages[from...] {
            if DraftCards.isNormalHumanTurn(m) { triggers = true; break }
            if m.role == .user, m.parts.contains(where: { if case .text(let t) = $0 { return answer(in: t) != nil } else { return false } }) {
                triggers = true; break
            }
            if m.role == .assistant, m.parts.contains(where: { if case .tool(let c) = $0, c.name == tool { return parse(c) != nil } else { return false } }) {
                triggers = true; break
            }
        }
        guard triggers else { return from }
        let scanFloor = max(floor, from - 120)
        var lowest = from
        var i = from - 1
        while i >= scanFloor {
            if messages[i].role == .assistant, messages[i].parts.contains(where: { if case .tool(let c) = $0, c.name == tool { return parse(c) != nil } else { return false } }) {
                lowest = i
            }
            i -= 1
        }
        return lowest
    }

    /// What follows the app on the source line: "Dana Reyes · DM · 11:03 AM" (the parts the bot gave).
    static func sourceDetail(_ ask: Ask) -> String {
        [ask.from, ask.place, ask.when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// [asks v2] The reply block's header: "Reply to Dana Reyes · Slack", or "Reply on Slack" when the bot named no one.
    static func replyHeading(_ to: ReplyTo) -> String {
        to.to.isEmpty ? "Reply on \(to.app)" : "Reply to \(to.to) · \(to.app)"
    }

    /// [asks v2] How VoiceOver reads the reply block: "Reply to Dana Reyes on Slack: <words>".
    static func replySpoken(_ to: ReplyTo, _ reply: String) -> String {
        (to.to.isEmpty ? "Reply on \(to.app)" : "Reply to \(to.to) on \(to.app)") + ": " + reply
    }

    /// The choice's words as the answer's second line: "Yes." ("Really?" keeps its own mark).
    static func sentence(_ choice: String) -> String {
        guard let last = choice.last, !".!?…".contains(last) else { return choice }
        return choice + "."
    }

    // MARK: The answers

    /// What a choice's button sends (`index` 0-based).
    static func choiceMessage(_ ask: Ask, index: Int) -> String? {
        guard ask.choices.indices.contains(index) else { return nil }
        let then = ask.then.isEmpty ? "" : " Go on as you said: \(ask.then)"
        return ["[Hermes HQ ask \(ask.id): \(index + 1)]", sentence(ask.choices[index]),
                "(Your question was: \"\(ask.question)\"\(then))"].joined(separator: "\n")
    }

    /// What "Something else…" sends: your own words.
    static func otherMessage(_ ask: Ask, text: String) -> String {
        ["[Hermes HQ ask \(ask.id): other]", text.trimmingCharacters(in: .whitespacesAndNewlines),
         "(Your question was: \"\(ask.question)\")"].joined(separator: "\n")
    }

    /// [asks v2] Send under a choice's ready reply: the choice, where the reply goes, then the reply (`reply`: the
    /// card's words, your edits included). The bot sends it with its own tool for the place, as a draft card's Send.
    ///
    ///     [Hermes HQ ask a-1a2b3c4d: 1 send]
    ///     Yes. Send this to Dana Reyes (Slack) exactly as written:
    ///
    ///     <the reply>
    static func sendMessage(_ ask: Ask, index: Int, reply: String) -> String? {
        guard ask.choices.indices.contains(index), let to = ask.replyTo, let own = Self.reply(ask, index: index) else { return nil }
        let final = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = final != own
        let place = to.to.isEmpty ? "Send this on \(to.app)" : "Send this to \(to.to) (\(to.app))"
        var lines = ["[Hermes HQ ask \(ask.id): \(index + 1) send]",
                     (edited ? editedLead : "") + sentence(ask.choices[index]) + " " + place
                         + (to.from.isEmpty ? "" : " from \(to.from)") + written]
        if !to.subject.isEmpty { lines.append("Subject: \(to.subject)") }
        return lines.joined(separator: "\n") + "\n\n" + final
    }

    private static let written = " exactly as written:"
    private static let editedLead = "I edited it. "

    /// How every answer starts.
    static let markLead = "[Hermes HQ ask "
    /// "other send" is not an answer: only a choice carries a reply.
    private static let mark = TRx(#"^\s*\[Hermes HQ ask (a-[0-9a-f]{8}): ([1-3]( send)?|other)\]"#)
    /// A send answer's second line: the choice's words before "Send this to …" / "Send this on …".
    private static let sendLine = TRx(#"^(?:I edited it\. )?(.*?) Send this (?:to|on) "#)

    /// The card a message of yours answers, and how.
    static func answer(in text: String) -> (id: String, answer: Answer)? {
        guard text.drop(while: \.isWhitespace).hasPrefix(markLead), let g = mark.groups(text), let id = g[1], let kind = g[2] else { return nil }
        let words = secondLine(text)
        if kind == "other" { return (id, .other(words)) }
        guard let n = Int(kind.prefix(1)) else { return nil }
        guard g.count > 3, g[3] != nil, let whole = g[0] else { return (id, .choice(n, words)) }
        // `N send`: the choice's words lead the second line; the reply follows the blank line.
        let choice = sendLine.groups(words).flatMap { $0[1] } ?? ""
        let rest = text.dropFirst(whole.count)
        let reply = rest.range(of: "\n\n").map { rest[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (id, .sent(n, choice, reply: reply))
    }

    /// The first line after the mark.
    private static func secondLine(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
    }

    /// A choice's words without the full stop its message added.
    static func choiceWords(_ line: String) -> String {
        line.hasSuffix(".") && !line.hasSuffix("..") ? String(line.dropLast()) : line
    }

    /// Your bubble's words for an answer: the choice ("Yes"), or what you typed; the card above shows the question.
    static func bubbleWords(_ text: String) -> String? {
        guard let found = answer(in: text) else { return nil }
        switch found.answer {
        case .choice(let n, let line):
            let words = choiceWords(line)
            return words.isEmpty ? "Choice \(n)" : words
        case .other(let words):
            return words.isEmpty ? "Something else" : words
        case .sent(let n, let line, _):
            // [asks v2] "Yes · Send the reply", or "Yes · Send it with my edits".
            let words = choiceWords(line)
            let send = text.contains("]\n" + editedLead) ? "Send it with my edits" : "Send the reply"
            return (words.isEmpty ? "Choice \(n)" : words) + " · " + send
        }
    }

    /// Every card the chat's messages answer, by ask id (the newest answer wins). `queued`: answers of yours still
    /// waiting behind a running reply; they count too (they are newer).
    static func answers(_ messages: [ChatMessage], queued: [String] = []) -> [String: Answer] {
        var out: [String: Answer] = [:]
        for message in messages where message.role == .user {
            for part in message.parts {
                guard case .text(let text) = part, let found = answer(in: text) else { continue }
                out[found.id] = found.answer
            }
        }
        for text in queued {
            if let found = answer(in: text) { out[found.id] = found.answer }
        }
        return out
    }

    /// Positional answer map keyed by ask `rowId`, preventing identical repeat asks from colliding with an earlier
    /// answer: each user answer matches only the latest ask with the same `ask.id` appearing before it, and tracks
    /// delivery state (`sent`, `sending`, `queued`, `failed`).
    static func answersByRow(_ messages: [ChatMessage], queued: [String] = []) -> [String: RowAnswer] {
        var latestRowByAskId: [String: String] = [:]
        var out: [String: RowAnswer] = [:]
        for message in messages {
            switch message.role {
            case .assistant:
                for part in message.parts {
                    guard case .tool(let call) = part, call.name == tool, let ask = parse(call) else { continue }
                    latestRowByAskId[ask.id] = rowId(messageId: message.id, callId: call.id)
                }
            case .user:
                let delivery: DeliveryState = message.error != nil ? .failed : (message.isPending ? .sending : .sent)
                for part in message.parts {
                    guard case .text(let text) = part, let found = answer(in: text),
                          let targetRowId = latestRowByAskId[found.id] else { continue }
                    out[targetRowId] = RowAnswer(answer: found.answer, delivery: delivery)
                }
            case .system:
                break
            }
        }
        for text in queued {
            if let found = answer(in: text), let targetRowId = latestRowByAskId[found.id] {
                out[targetRowId] = RowAnswer(answer: found.answer, delivery: .queued)
            }
        }
        return out
    }

    /// Short answer phrase for compact receipts ("Yes", "Yes · Reply sent", or what you typed).
    static func receiptTitle(_ ask: Ask, _ answer: Answer, delivery: DeliveryState = .sent) -> String {
        let base: String
        switch answer {
        case .choice(let n, let line):
            let words = ask.choices.indices.contains(n - 1) ? choiceTitle(ask.choices[n - 1]) : choiceWords(line)
            base = words.isEmpty ? "Choice \(n)" : words
        case .other(let words):
            base = words.isEmpty ? "Something else" : words
        case .sent(let n, let line, _):
            let words = ask.choices.indices.contains(n - 1) ? choiceTitle(ask.choices[n - 1]) : choiceWords(line)
            let lead = words.isEmpty ? "Choice \(n)" : words
            base = delivery == .sent ? "\(lead) · Reply approved" : lead
        }
        switch delivery {
        case .sent: return base
        case .sending: return "Sending… · \(base)"
        case .queued: return "Queued · \(base)"
        case .failed: return "Not sent · \(base)"
        }
    }

    /// The quiet line an answered card shows: "You answered: Yes".
    static func status(_ ask: Ask, _ answer: Answer) -> String {
        switch answer {
        case .choice(let n, let line):
            let words = ask.choices.indices.contains(n - 1) ? choiceTitle(ask.choices[n - 1]) : choiceWords(line)
            return "You answered: \(words)"
        case .other(let words):
            return "You answered: \(words.isEmpty ? "something else" : words)"
        case .sent(let n, let line, _):
            // [asks v2] "You answered: Yes · Reply approved" (the reply that went shows under it).
            let words = ask.choices.indices.contains(n - 1) ? choiceTitle(ask.choices[n - 1]) : choiceWords(line)
            return "You answered: \(words) · Reply approved"
        }
    }
}
