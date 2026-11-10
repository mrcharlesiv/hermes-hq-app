import UIKit

// [drafts] The chat screen's side of a draft card (HermesKit/Drafts/DraftCards.swift): Send and Don't Send go into the
// chat as your message naming the draft; Edit puts the draft's words in the message field under an "Editing Draft"
// strip with Cancel and Save, as a queued message's edit does (ChatViewController+QueueEdit.swift). Save changes the
// card's words, here only: nothing goes to the bot until Send.

/// Your unsent changes to draft cards, kept while the app runs (a chat left and reopened still shows them).
@MainActor final class DraftEdits {
    static let shared = DraftEdits()
    /// "<chat scope>|<draft id>" → the words.
    private var texts: [String: String] = [:]
    /// The draft whose words are in a message field, by the same key.
    private(set) var editing: String?

    private func key(_ scope: String, _ id: String) -> String { scope + "|" + id }

    func rowsInput(_ messages: [ChatMessage], queued: [String] = [], scope: String) -> DraftRowsInput {
        var input = DraftRowsInput(answers: DraftCards.answers(messages, queued: queued))
        let lead = scope + "|"
        for (key, text) in texts where key.hasPrefix(lead) { input.edits[String(key.dropFirst(lead.count))] = text }
        if let editing, editing.hasPrefix(lead) { input.editing = String(editing.dropFirst(lead.count)) }
        return input
    }

    /// `text` nil (or the bot's own words) forgets the change.
    func set(_ text: String?, scope: String, draft: DraftCards.Draft) {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        texts[key(scope, draft.id)] = (words?.isEmpty == false && words != draft.body) ? words : nil
    }

    func setEditing(_ id: String?, scope: String) { editing = id.map { key(scope, $0) } }
}

extension ChatViewController {
    /// Your answers still waiting behind a running reply (the queue): their cards show them as answered too.
    var draftQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter { $0.hasPrefix(DraftCards.markLead) } ?? []
    }

    /// The chat changed: a card whose answer arrived some other way than its own buttons (another device, the desktop,
    /// the queue going out or a queued answer taken back) is drawn again. Returns the messages to rebuild.
    func draftMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = DraftCards.answers(messages, queued: draftQueuedTexts)
        guard now != draftAnswersShown else { return [] }
        let changed = Set(now.keys).union(draftAnswersShown.keys).filter { now[$0] != draftAnswersShown[$0] }
        draftAnswersShown = now
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part, let draft = DraftCards.draft(call) else { return false }
                return changed.contains(draft.id)
            }
        }.map(\.id)
    }

    func draftCardTapped(_ card: DraftCardRow, _ button: DraftButton) {
        guard card.state == .waiting else { return }
        switch button {
        case .send:
            Haptics.play(.selection)
            answerDraft(card, DraftCards.sendMessage(card.draft, body: card.body))
        case .skip:
            Haptics.play(.selection)
            answerDraft(card, DraftCards.skipMessage(card.draft))
        case .edit:
            beginDraftEdit(card)
        }
    }

    /// Your answer goes into the chat as a message of yours (its bubble reads "Send it"); the card then shows it.
    private func answerDraft(_ card: DraftCardRow, _ text: String) {
        AppLog.trace("drafts", "draft \(AppLog.tag(card.draft.id)) answered \(logTag)")
        DraftEdits.shared.set(nil, scope: scope, draft: card.draft)
        // `display` given: the words go out as they are (a task's chat wraps typed words; the mark must lead).
        sendFromCard(text, display: text)
        rebuildMessage(card.messageId)
    }

    private func beginDraftEdit(_ card: DraftCardRow) {
        // One strip at a time: a message edit, a queued edit or a reply in progress gives way first.
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        let typed = composer.text
        let banner = ComposerEditBanner(title: "Editing Draft", symbol: "pencil", note: nil, cancelLabel: "Cancel",
                                        identifier: "composer.editingDraft", saves: true)
        let close: (ChatViewController) -> Void = { screen in
            screen.sendOverride = nil
            screen.composer.editingQueued = false
            screen.composer.editBanner = nil
            screen.composer.text = typed
            DraftEdits.shared.setEditing(nil, scope: screen.scope)
            screen.rebuildMessage(card.messageId)
        }
        banner.onCancel = { [weak self] in
            guard let self else { return }
            close(self)
        }
        let save: (String) -> Void = { [weak self] text in
            guard let self else { return }
            DraftEdits.shared.set(text, scope: self.scope, draft: card.draft)
            AppLog.trace("drafts", "draft \(AppLog.tag(card.draft.id)) edit saved \(self.logTag)")
            close(self)
        }
        banner.onSave = { [weak self] in
            guard let self else { return }
            let text = ComposerKeyboard.sendText(self.composer.text)
            guard !text.isEmpty else { return }
            Haptics.play(.selection)
            save(text)
        }
        composer.editBanner = banner
        composer.editingQueued = true   // the circle reads Save and the mic steps aside, as for a queued message
        composer.text = card.body
        // The circle and Return save (a blank field keeps editing).
        sendOverride = { text in
            if !text.isEmpty { save(text) }
            return true
        }
        DraftEdits.shared.setEditing(card.draft.id, scope: scope)
        rebuildMessage(card.messageId)
        focusComposer()
    }
}
