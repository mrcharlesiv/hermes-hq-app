// [drafts] A bot's draft for review (the add-on's `draft_message`, hermes-hq-push 0.9.47 drafts.py): a message the
// bot wrote for the person to send to someone else (Slack, email, a text), drawn in the chat as a card with the text,
// Send, Edit and Don't Send. The tool sends nothing and doesn't wait: the card is the tool call, and the person's
// answer goes back as an ordinary message whose first line names the draft:
//
//     [Hermes HQ draft d-1a2b3c4d: send]
//     Send this to #finance (Slack) exactly as written:
//
//     <the final text, edits included>
//
//     [Hermes HQ draft d-1a2b3c4d: skip]
//     Don't send this draft.
//
// The bot then sends that text with its own tool for the place. Everything here reads the transcript alone, so a
// card shows the same state after a relaunch and on another device: answered once a later message of yours names it.
// A draft's id is made from its words (the add-on makes the same one), so nothing depends on the tool's result.

import CryptoKit
import Foundation

nonisolated enum DraftCards {
    static let tool = "draft_message"
    /// A draft call's arguments are kept whole up to this size (the add-on takes 20,000 characters of body), not cut
    /// to the 4 KB every other call's are (`ToolArgs.maxBytes`): the card draws them, and Send sends them.
    static let maxArgsBytes = 256_000
    /// The card shows this many messages of the conversation a draft answers (the add-on's MAX_THREAD): the newest.
    static let maxThread = 30

    /// One earlier message of the conversation a draft answers (`thread`): who, when (as the bot said it), the words.
    struct Message: Hashable, Sendable {
        var from: String
        var when: String
        var text: String
    }

    struct Draft: Hashable, Sendable {
        var id: String
        /// Where it goes, as the bot named it: "Slack", "Email".
        var app: String
        /// Who or where: "#finance", "dana@example.com". May be empty.
        var to: String
        var subject: String
        var body: String
        /// The account or address it's sent from, when the bot said (`from`, or "Email — from me@x.com" in `app`).
        var from: String = ""
        /// `app` without what the bot added to it: "Email" of "Email — from me@x.com".
        var appName: String = ""
        /// What else the bot put in `app` that isn't a sender: "Acme workspace" of "Slack (Acme workspace)".
        var via: String = ""
        /// The conversation it answers, oldest first, the message being answered last. Empty when the bot gave none.
        var thread: [Message] = []
    }

    /// One labelled line of the card's header: To, From, Via, Subject.
    struct Field: Hashable, Sendable {
        var label: String
        var value: String
        var strong = false
    }

    enum Answer: Hashable, Sendable {
        /// Send, with the text that went back when the message carries it (the person's edits included).
        case send(body: String?)
        case skip
    }

    // MARK: The add-on

    /// PUT here (under the add-on's route) says an app that draws draft cards uses this computer; until then the
    /// add-on keeps `draft_message` from its bots, so a draft is never left where nobody sees a card.
    static let cardsPath = "/drafts/cards"

    /// The add-on has `draft_message` (0.9.47's `draftCards`) and hasn't heard from such an app (`draftCardsShown`).
    static func cardsUntold(_ status: [String: Any]?) -> Bool {
        (status?["draftCards"] as? NSNumber)?.boolValue == true && (status?["draftCardsShown"] as? NSNumber)?.boolValue != true
    }

    // MARK: The call

    /// A draft call's arguments as text, whole; nil for any other tool or one too big to keep.
    static func wholeArgsText(name: String, args: [String: JSONValue]) -> String? {
        guard name == tool, !args.isEmpty else { return nil }
        let text = ChatJSON.stringify(.object(args))
        return text.utf8.count <= maxArgsBytes ? text : nil
    }

    /// The draft a tool call holds; nil when it isn't one, it failed, or its arguments aren't whole (a cached
    /// transcript cuts them: the call then draws as the plain step it is until the stored chat is read again).
    static func draft(_ call: ToolCall) -> Draft? {
        guard call.name == tool, call.state != .failed, let text = call.argsText,
              let args = ChatJSON.parse(string: text)?.object else { return nil }
        let body = trimmed(args["body"])
        let app = trimmed(args["app"])
        guard !body.isEmpty, !app.isEmpty else { return nil }
        let to = trimmed(args["to"]), subject = trimmed(args["subject"])
        var draft = Draft(id: id(app: app, to: to, subject: subject, body: body), app: app, to: to, subject: subject, body: body)
        let parts = split(app: app)
        draft.appName = parts.name
        draft.via = parts.via
        let from = trimmed(args["from"])
        draft.from = from.isEmpty ? parts.from : from
        draft.thread = thread(args["thread"])
        return draft
    }

    /// The `thread` argument as messages: objects of {from, when, text} (a bot's near names for them read too) or bare
    /// strings; ones without words are left out, and only the newest `maxThread` are kept.
    static func thread(_ value: JSONValue?) -> [Message] {
        guard let items = value?.array else { return [] }
        func first(_ object: [String: JSONValue], _ keys: [String]) -> String {
            for key in keys {
                let found = trimmed(object[key])
                if !found.isEmpty { return found }
            }
            return ""
        }
        let messages: [Message] = items.compactMap { item in
            if let object = item.object {
                let text = first(object, ["text", "body", "content", "message"])
                guard !text.isEmpty else { return nil }
                return Message(from: first(object, ["from", "sender", "author", "name"]),
                               when: first(object, ["when", "time", "date", "sent"]), text: text)
            }
            let text = trimmed(item)
            return text.isEmpty ? nil : Message(from: "", when: "", text: text)
        }
        return Array(messages.suffix(maxThread))
    }

    /// A bot may say more than the app's name in `app` ("Email — from me@x.com", "Slack (Acme workspace)"): the
    /// name is what comes before the first break, a sender is what follows "from", anything else is `via`.
    static func split(app: String) -> (name: String, from: String, via: String) {
        var cut: Range<String.Index>?
        for mark in [" — ", " – ", " - ", " (", ", ", ": ", " from ", " via "] {
            if let found = app.range(of: mark, options: .caseInsensitive), cut.map({ found.lowerBound < $0.lowerBound }) ?? true { cut = found }
        }
        guard let cut, cut.lowerBound > app.startIndex else { return (app, "", "") }
        let name = app[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
        let lead = app[cut].trimmingCharacters(in: .whitespaces).lowercased()
        var rest = app[cut.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        var isFrom = lead == "from"
        for word in ["from ", "via "] where rest.lowercased().hasPrefix(word) {
            isFrom = word == "from "
            rest = String(rest.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty, !rest.isEmpty else { return (app, "", "") }
        return isFrom ? (name, rest, "") : (name, "", rest)
    }

    /// "d-" and the first 8 hex digits of SHA-256 over the four values joined by newlines, as drafts.py `draft_id`.
    static func id(app: String, to: String, subject: String, body: String) -> String {
        let digest = SHA256.hash(data: Data([app, to, subject, body].joined(separator: "\n").utf8))
        return "d-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func trimmed(_ value: JSONValue?) -> String {
        (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Words

    static func name(_ draft: Draft) -> String { draft.appName.isEmpty ? draft.app : draft.appName }

    /// "#finance (Slack)", or "Slack" when the bot named no one.
    static func place(_ draft: Draft) -> String {
        draft.to.isEmpty ? name(draft) : "\(draft.to) (\(name(draft)))"
    }

    /// The round mark beside the header: an envelope for mail, a bubble for a chat app, a pencil for anything else.
    static func glyph(_ draft: Draft) -> String {
        let kind = name(draft).lowercased()
        if ["mail", "gmail", "outlook"].contains(where: kind.contains) { return "envelope.circle.fill" }
        if ["slack", "telegram", "discord", "message", "text", "whatsapp", "sms", "signal", "teams"].contains(where: kind.contains) {
            return "bubble.left.circle.fill"
        }
        return "square.and.pencil.circle.fill"
    }

    /// The button under the preview that opens the conversation a draft answers.
    static func threadTitle(_ draft: Draft) -> String {
        draft.thread.count == 1 ? "Show Whole Message" : "Show Conversation (\(draft.thread.count))"
    }

    /// The card's header: "Email draft", "Slack draft".
    static func heading(_ draft: Draft) -> String { "\(name(draft)) draft" }

    /// The lines under the header, in a letter's order; the ones the bot left out aren't there.
    static func fields(_ draft: Draft) -> [Field] {
        var out: [Field] = []
        if !draft.to.isEmpty { out.append(Field(label: "To", value: draft.to)) }
        if !draft.from.isEmpty { out.append(Field(label: "From", value: draft.from)) }
        if !draft.via.isEmpty { out.append(Field(label: "Via", value: draft.via)) }
        if !draft.subject.isEmpty { out.append(Field(label: "Subject", value: draft.subject, strong: true)) }
        return out
    }

    // MARK: The answer

    private static let written = " exactly as written:"
    private static let editedLead = "I edited it. "

    /// What Send sends into the chat: the mark, where it goes, then `body` (the card's text, edits included).
    static func sendMessage(_ draft: Draft, body: String) -> String {
        let final = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = final != draft.body
        var lines = ["[Hermes HQ draft \(draft.id): send]",
                     (edited ? editedLead : "") + (draft.to.isEmpty ? "Send this on \(name(draft))" : "Send this to \(place(draft))")
                         + (draft.from.isEmpty ? "" : " from \(draft.from)") + (draft.via.isEmpty ? "" : " (\(draft.via))") + written]
        if !draft.subject.isEmpty { lines.append("Subject: \(draft.subject)") }
        return lines.joined(separator: "\n") + "\n\n" + final
    }

    /// What Don't Send sends.
    static func skipMessage(_ draft: Draft) -> String {
        "[Hermes HQ draft \(draft.id): skip]\nDon't send this draft."
    }

    /// How every answer starts.
    static let markLead = "[Hermes HQ draft "
    private static let mark = TRx(#"^\s*\[Hermes HQ draft (d-[0-9a-f]{8}): (send|skip)\]"#)

    /// The draft a message of yours answers, and how.
    static func answer(in text: String) -> (id: String, answer: Answer)? {
        guard text.drop(while: \.isWhitespace).hasPrefix(markLead), let groups = mark.groups(text), let whole = groups[0], let id = groups[1] else { return nil }
        if groups[2] == "skip" { return (id, .skip) }
        let rest = text.dropFirst(whole.count)
        guard let gap = rest.range(of: "\n\n") else { return (id, .send(body: nil)) }
        let body = rest[gap.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (id, .send(body: body.isEmpty ? nil : body))
    }

    /// Your bubble's words for an answer: the mark and the draft's text aren't repeated under the card that shows them.
    static func bubbleWords(_ text: String) -> String? {
        guard let found = answer(in: text) else { return nil }
        switch found.answer {
        case .skip: return "Don’t send it"
        case .send: return text.contains("]\n" + editedLead) ? "Send it with my edits" : "Send it"
        }
    }

    /// Every draft the chat's messages answer, by draft id (the newest answer wins).
    /// `queued`: answers of yours still waiting behind a running reply; they count too (they are newer).
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
}
