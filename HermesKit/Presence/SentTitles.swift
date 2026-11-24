// [presence] A request sent with a short title for its bubble (docs/spec/3x-presence.md §10: "Install the Hermes HQ
// browser plugin on this Hermes."). The stored row holds the whole prompt, so wherever the chat reads its transcript
// (at the end of every reply, from its cache when it opens, and when older rows load) the bubble would swap its title
// for the long prompt. This maps the stored prompt back to its title. The app's one fixed pair (the browser plugin's
// request) is noted at sign-in, so the title also shows after a relaunch and on a phone that did not send it; others
// last for the run. A handful of entries, matched on the exact prompt.
//
// The other direction too: a refused send hands the bubble's words (the title) back to the field, and a queue row
// taken out to edit does the same. Sent again from the main bot's field, the title goes out as the request it stands
// for (`prompt(forTitle:)`), never as its bare sentence.

import Foundation

nonisolated struct SentTitles: Sendable {
    static let limit = 8

    /// The prompt as stored (whitespace flattened) → the title its bubble shows.
    private var titles: [String: String] = [:]
    /// The same key → the prompt as it was sent (line breaks and all), for sending it again.
    private var prompts: [String: String] = [:]
    private var order: [String] = []

    var isEmpty: Bool { titles.isEmpty }

    mutating func note(text: String, title: String) {
        let key = ChatText.flat(text)
        guard !key.isEmpty, !title.isEmpty, key != ChatText.flat(title) else { return }
        if titles[key] == nil { order.append(key) }
        titles[key] = title
        prompts[key] = text
        while order.count > Self.limit {
            let dropped = order.removeFirst()
            titles[dropped] = nil
            prompts[dropped] = nil
        }
    }

    /// [goals step 3] A goal's Plan With ask carries your words in it, so its bubble keeps them after a relaunch and on
    /// another device too, with no entry noted here.
    /// [phone-calls] A call's result message shows its short line, and a message that carried the call note shows the
    /// words without it (PhoneChatText).
    func title(forStored text: String) -> String? {
        if let inner = ThreadContextNote.stripped(text) { return title(forStored: inner) ?? inner }
        if let inner = PhoneChatNote.stripped(text) { return title(forStored: inner) ?? inner }
        return titles[ChatText.flat(text)] ?? GoalBots.planBubble(forStored: text) ?? PhoneResultMessage.bubble(forStored: text)
    }

    /// The request a title stands for, when `typed` is exactly one of the titles (whitespace aside).
    func prompt(forTitle typed: String) -> String? {
        let wanted = ChatText.flat(typed)
        guard !wanted.isEmpty, let key = order.last(where: { titles[$0].map(ChatText.flat) == wanted }) else { return nil }
        return prompts[key]
    }

    /// Stored rows as the chat shows them: a user row that is one of the titled prompts shows its title.
    func applied(to messages: [ChatMessage]) -> [ChatMessage] {
        guard !titles.isEmpty || messages.contains(where: { $0.role == .user && ($0.plainText.hasPrefix(GoalBots.planRequestStart)
                                                                                   || PhoneChatText.rewrites($0.plainText)
                                                                                   || ThreadContextNote.hasNote($0.plainText)) })
        else { return messages }
        return messages.map { message in
            guard message.role == .user, let title = title(forStored: message.plainText) else { return message }
            var shown = message
            if PhoneResultMessage.bubble(forStored: message.plainText) != nil { shown.phoneResultText = message.plainText }
            shown.parts = message.parts.filter { if case .text = $0 { return false } else { return true } } + [.text(title)]
            return shown
        }
    }
}
