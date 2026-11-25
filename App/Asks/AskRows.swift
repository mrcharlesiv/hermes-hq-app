import UIKit

// [asks] The chat's row for a bot's ask-to-act card (HermesKit/Asks/AskCards.swift): a pure value, built and measured
// on any thread like the draft and order cards' (App/Questions/PromptRows.swift, App/Shopping/ShoppingRows.swift).
// The drawing is AskCardView.swift; the chat screen's side ChatViewController+Asks.swift.

/// What the chat screen hands the row builder about its ask cards (`ChatRowBuilder.Input.asks`).
nonisolated struct AskRowsInput: Sendable, Equatable {
    /// Ask id → your answer, read from the chat's own messages (`AskCards.answers`).
    var answers: [String: AskCards.Answer] = [:]
    /// The ask whose "Something else…" strip is open over the message field.
    var answering: String? = nil
    /// [asks v2] Ask id → the choice (0-based) you tapped whose ready reply the card shows (nothing sent yet).
    var picked: [String: Int] = [:]
    /// [asks v2] "<ask id>|<choice index>" → the words you changed that choice's reply to, not sent yet.
    var edits: [String: String] = [:]
    /// [asks v2] The ask whose reply is in the message field ("Editing Reply").
    var editingReply: String? = nil
    /// [calm-chat] Ask row ids left unanswered after later turns; nil computes from `messages`.
    var stale: Set<String>? = nil

    static func editKey(_ id: String, _ index: Int) -> String { "\(id)|\(index)" }
}

/// An `ask_to_act` call's row.
nonisolated struct AskCardRow: Sendable, Hashable {
    var ask: AskCards.Ask
    var rowId: String
    var messageId: String
    /// Your answer, once a message of yours (or a queued one) names the card.
    var answer: AskCards.Answer?
    /// Its "Something else…" strip is open (the buttons wait).
    var answering: Bool
    /// [asks v2] The choice you picked whose ready reply shows under the buttons (while it waits).
    var picked: Int? = nil
    /// [asks v2] The reply the card shows for `picked`: your edit, or the bot's words.
    var reply: String? = nil
    /// [asks v2] `reply` isn't the bot's words any more.
    var edited = false
    /// [asks v2] The reply is in the message field (the buttons wait).
    var editingReply = false
    /// [asks v2] Show All was tapped on a long reply, or a folded/answered receipt was expanded.
    var expanded = false
    /// [calm-chat] Unanswered ask left behind by later conversation; drops live buttons and folds quietly.
    var stale = false

    var waiting: Bool { answer == nil && !stale }
    var isQuietFolded: Bool { stale && answer == nil && !expanded }
}

nonisolated extension PromptRows {
    /// A ready reply shows this many lines until Show All (a draft's own clamp); the one that went, this many.
    static let askReplyLines = draftClampLines, askSentLines = 3

    /// An `ask_to_act` tool part's row; nil when the call can't be read (it draws as the step it is).
    static func askRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        guard let ask = AskCards.parse(call) else { return nil }
        let id = AskCards.rowId(messageId: message.id, callId: call.id)
        let answer = input.asks.answers[ask.id]
        let stale = answer == nil && (input.asks.stale ?? AskCards.staleRowIds(input.messages)).contains(id)
        var card = AskCardRow(ask: ask, rowId: id, messageId: message.id, answer: answer,
                              answering: answer == nil && !stale && input.asks.answering == ask.id,
                              expanded: input.expanded.contains(id), stale: stale)
        if answer == nil, !stale, let index = input.asks.picked[ask.id], let own = AskCards.reply(ask, index: index) {
            card.picked = index
            card.reply = input.asks.edits[AskRowsInput.editKey(ask.id, index)] ?? own
            card.edited = card.reply != own
            card.editingReply = input.asks.editingReply == ask.id
        }
        return row(id: id, messageId: message.id, kind: .ask(card), scope: input.scope)
    }
}
