import UIKit

// [asks] The chat screen's side of an ask card (HermesKit/Asks/AskCards.swift): a choice's button goes into the chat
// as your message naming the card (`sendFromCard`), as a draft card's Send does; "Something else…" opens a strip over
// the message field ("Answering: …", Cancel), as a draft's Edit does, and what you then send goes out as the card's
// `other` answer. The card is drawn again in its new state. [asks v2] A choice with a ready reply only picks it; the
// reply's Send answers with the choice and the reply, its Edit opens the draft card's "Editing Reply" strip.

/// The ask whose "Something else…" strip is open, and (v2) the choices you picked, your unsent changes to their ready
/// replies and the reply being edited: kept while the app runs (a chat left and reopened still shows them), as
/// `DraftEdits` keeps a draft card's.
@MainActor final class AskAnswering {
    static let shared = AskAnswering()
    /// "<chat scope>|<ask id>".
    private(set) var current: String?
    /// [asks v2] "<chat scope>|<ask id>" → the picked choice (0-based).
    private var picks: [String: Int] = [:]
    /// [asks v2] "<chat scope>|<ask id>|<choice index>" → the words.
    private var texts: [String: String] = [:]
    /// [asks v2] "<chat scope>|<ask id>" whose reply is in a message field.
    private(set) var editing: String?

    func rowsInput(_ messages: [ChatMessage], queued: [String] = [], scope: String) -> AskRowsInput {
        var input = AskRowsInput(answers: AskCards.answers(messages, queued: queued),
                                 stale: AskCards.staleRowIds(messages))
        let lead = scope + "|"
        func own(_ key: String) -> String? { key.hasPrefix(lead) ? String(key.dropFirst(lead.count)) : nil }
        if let current { input.answering = own(current) }
        for (key, index) in picks { if let id = own(key) { input.picked[id] = index } }
        for (key, text) in texts { if let id = own(key) { input.edits[id] = text } }
        if let editing { input.editingReply = own(editing) }
        return input
    }

    func set(_ id: String?, scope: String) { current = id.map { scope + "|" + $0 } }

    /// [asks v2] Show `index`'s ready reply (nil: none picked).
    func pick(_ index: Int?, scope: String, ask: String) { picks[scope + "|" + ask] = index }

    /// [asks v2] `text` nil (or the bot's own words) forgets the change.
    func setReply(_ text: String?, scope: String, ask: AskCards.Ask, index: Int) {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        texts[scope + "|" + AskRowsInput.editKey(ask.id, index)] = (words?.isEmpty == false && words != AskCards.reply(ask, index: index)) ? words : nil
    }

    /// [asks v2] Forget an answered card's picks and edits.
    func forget(scope: String, ask: AskCards.Ask) {
        picks[scope + "|" + ask.id] = nil
        for i in ask.choices.indices { texts[scope + "|" + AskRowsInput.editKey(ask.id, i)] = nil }
    }

    func setEditing(_ id: String?, scope: String) { editing = id.map { scope + "|" + $0 } }
}

extension ChatViewController {
    /// Your answers still waiting behind a running reply (the queue): their cards show them as answered too.
    var askQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter { $0.hasPrefix(AskCards.markLead) } ?? []
    }

    /// The chat changed: a card whose answer arrived some other way than its own buttons (another device, the queue
    /// going out or a queued answer taken back) is drawn again. Returns the messages to rebuild.
    func askMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = AskCards.answers(messages, queued: askQueuedTexts)
        guard now != askAnswersShown else { return [] }
        let changed = Set(now.keys).union(askAnswersShown.keys).filter { now[$0] != askAnswersShown[$0] }
        askAnswersShown = now
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part, call.name == AskCards.tool, let ask = AskCards.parse(call) else { return false }
                return changed.contains(ask.id)
            }
        }.map(\.id)
    }

    // MARK: ChatPromptCellHandling

    func askCard(_ card: AskCardRow, chose index: Int) {
        guard card.waiting else { return }
        // [asks v2] A choice with a ready reply only picks it: the card shows the reply with Send and Edit.
        if AskCards.reply(card.ask, index: index) != nil {
            guard card.picked != index else { return }
            AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) picked \(index + 1) \(logTag)")
            Haptics.play(.selection)
            AskAnswering.shared.pick(index, scope: scope, ask: card.ask.id)
            rebuildMessage(card.messageId)
            return
        }
        guard let text = AskCards.choiceMessage(card.ask, index: index) else { return }
        AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) choice \(index + 1) \(logTag)")
        Haptics.play(.selection)
        answerAsk(card, text)
    }

    /// [asks v2] Send under the ready reply answers with the choice and the reply (your edits included); Edit puts the
    /// reply in the message field under an "Editing Reply" strip, as a draft card's Edit does.
    func askCardReply(_ card: AskCardRow, tapped button: DraftButton) {
        guard card.waiting, let index = card.picked, let reply = card.reply else { return }
        switch button {
        case .send:
            guard let text = AskCards.sendMessage(card.ask, index: index, reply: reply) else { return }
            AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) choice \(index + 1) send\(card.edited ? " edited" : "") \(logTag)")
            Haptics.play(.selection)
            answerAsk(card, text)
        case .edit:
            beginAskReplyEdit(card, index: index, reply: reply)
        case .skip:
            break
        }
    }

    private func beginAskReplyEdit(_ card: AskCardRow, index: Int, reply: String) {
        // One strip at a time: a message edit, a queued edit, a draft's edit or a reply in progress gives way first.
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        let typed = composer.text
        let banner = ComposerEditBanner(title: "Editing Reply", symbol: "pencil", note: nil, cancelLabel: "Cancel",
                                        identifier: "composer.editingReply", saves: true)
        let close: (ChatViewController) -> Void = { screen in
            screen.sendOverride = nil
            screen.composer.editingQueued = false
            screen.composer.editBanner = nil
            screen.composer.text = typed
            AskAnswering.shared.setEditing(nil, scope: screen.scope)
            screen.rebuildMessage(card.messageId)
        }
        banner.onCancel = { [weak self] in
            guard let self else { return }
            close(self)
        }
        let save: (String) -> Void = { [weak self] text in
            guard let self else { return }
            AskAnswering.shared.setReply(text, scope: self.scope, ask: card.ask, index: index)
            AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) reply edit saved \(self.logTag)")
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
        composer.editingQueued = true   // the circle reads Save and the mic steps aside, as for a draft's edit
        composer.text = reply
        // The circle and Return save (a blank field keeps editing).
        sendOverride = { text in
            if !text.isEmpty { save(text) }
            return true
        }
        AskAnswering.shared.setEditing(card.ask.id, scope: scope)
        rebuildMessage(card.messageId)
        focusComposer()
    }

    func askCardOpen(_ card: AskCardRow) {
        guard let url = card.ask.link?.url else { return }
        AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) link opened \(logTag)")
        LinkOpener.open(url, from: self)
    }

    /// "Something else…": a strip over the message field; the send circle sends your words as the card's answer.
    func askCardOther(_ card: AskCardRow) {
        guard card.waiting else { return }
        // One strip at a time: a message edit, a queued edit, a draft's edit or a reply in progress gives way first.
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        let typed = composer.text
        let question = card.ask.question.count > 60 ? String(card.ask.question.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : card.ask.question
        let banner = ComposerEditBanner(title: "Answering: \(question)", symbol: "arrowshape.turn.up.left", note: nil, cancelLabel: "Cancel",
                                        identifier: "composer.answeringAsk", cancelInWords: true)
        let close: (ChatViewController, String) -> Void = { screen, restore in
            screen.sendOverride = nil
            screen.composer.editBanner = nil
            screen.composer.text = restore
            AskAnswering.shared.set(nil, scope: screen.scope)
            screen.rebuildMessage(card.messageId)
        }
        banner.onCancel = { [weak self] in
            guard let self else { return }
            close(self, typed)
        }
        composer.editBanner = banner
        composer.text = ""
        // The circle and Return send the words as the answer (a blank field keeps the strip open).
        sendOverride = { [weak self] text in
            guard let self else { return true }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return true }
            AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) other \(self.logTag)")
            Haptics.play(.selection)
            close(self, typed)
            self.answerAsk(card, AskCards.otherMessage(card.ask, text: words))
            return true
        }
        AskAnswering.shared.set(card.ask.id, scope: scope)
        rebuildMessage(card.messageId)
        focusComposer()
    }

    /// Your answer goes into the chat as a message of yours (its bubble reads "Yes"); the card then shows it.
    private func answerAsk(_ card: AskCardRow, _ text: String) {
        // `display` given: the words go out as they are (a task's chat wraps typed words; the mark must lead).
        sendFromCard(text, display: text)
        AskAnswering.shared.forget(scope: scope, ask: card.ask)   // [asks v2]
        rebuildMessage(card.messageId)
    }

    #if DEBUG
    /// `-HQDemoAskOther`: the newest ask card's "Something else…", as tapped (`-HQDemoAskOtherText <words>` types them).
    func debugAskOther(typing words: String?) {
        let input = AskAnswering.shared.rowsInput(session.messages, scope: scope)
        for m in session.messages.reversed() where m.role == .assistant {
            for case .tool(let call) in m.parts.reversed() {
                guard let ask = AskCards.parse(call), input.answers[ask.id] == nil else { continue }
                let row = AskCardRow(ask: ask, rowId: "\(m.id)|ask\(call.id)", messageId: m.id, answer: nil, answering: false)
                askCardOther(row)
                if let words { composer.text = words }
                return
            }
        }
    }

    /// [asks v2] `-HQDemoAskPick <n>`: the newest waiting ask card's choice n (1-based) picked, as tapped.
    func debugAskPick(_ n: Int) {
        let input = AskAnswering.shared.rowsInput(session.messages, scope: scope)
        for m in session.messages.reversed() where m.role == .assistant {
            for case .tool(let call) in m.parts.reversed() {
                guard let ask = AskCards.parse(call), input.answers[ask.id] == nil else { continue }
                let row = AskCardRow(ask: ask, rowId: "\(m.id)|ask\(call.id)", messageId: m.id, answer: nil, answering: false)
                askCard(row, chose: n - 1)
                return
            }
        }
    }
    #endif
}
