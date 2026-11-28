import UIKit

// [asks] The chat screen's side of an ask card (HermesKit/Asks/AskCards.swift): keyed per `rowId` so identical repeat
// asks never collide; toggling a picked v2 choice collapses its inline drawer; answering an inline card keeps scroll
// position calm instead of jumping to the bottom; external answers auto-dismiss any open composer strip for that card.

@MainActor final class AskAnswering {
    static let shared = AskAnswering()
    /// "<chat scope>|<rowId>".
    private(set) var current: String?
    /// [asks v2] "<chat scope>|<rowId>" → the picked choice (0-based).
    private var picks: [String: Int] = [:]
    /// [asks v2] "<chat scope>|<rowId>|<choice index>" → edited reply text.
    private var texts: [String: String] = [:]
    /// [asks v2] "<chat scope>|<rowId>" whose reply is currently in the message field.
    private(set) var editing: String?

    func rowsInput(_ messages: [ChatMessage], queued: [String] = [], scope: String) -> AskRowsInput {
        var input = AskRowsInput(
            answers: AskCards.answers(messages, queued: queued),
            rowAnswers: AskCards.answersByRow(messages, queued: queued),
            stale: AskCards.staleRowIds(messages)
        )
        let lead = scope + "|"
        func own(_ key: String) -> String? { key.hasPrefix(lead) ? String(key.dropFirst(lead.count)) : nil }
        if let current { input.answering = own(current) }
        for (key, index) in picks { if let id = own(key) { input.picked[id] = index } }
        for (key, text) in texts { if let id = own(key) { input.edits[id] = text } }
        if let editing { input.editingReply = own(editing) }
        return input
    }

    func set(_ rowId: String?, scope: String) { current = rowId.map { scope + "|" + $0 } }

    /// [asks v2] Show `index`'s inline ready reply for `rowId` (nil: none picked).
    func pick(_ index: Int?, scope: String, rowId: String) { picks[scope + "|" + rowId] = index }

    /// [asks v2] `text` nil (or the bot's own words) forgets the change.
    func setReply(_ text: String?, scope: String, rowId: String, ask: AskCards.Ask, index: Int) {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        texts[scope + "|" + AskRowsInput.editKey(rowId, index)] = (words?.isEmpty == false && words != AskCards.reply(ask, index: index)) ? words : nil
    }

    /// [asks v2] Forget an answered card's picks and edits.
    func forget(scope: String, rowId: String, ask: AskCards.Ask) {
        picks[scope + "|" + rowId] = nil
        for i in ask.choices.indices { texts[scope + "|" + AskRowsInput.editKey(rowId, i)] = nil }
    }

    func setEditing(_ rowId: String?, scope: String) { editing = rowId.map { scope + "|" + $0 } }

    func activeRowId(in scope: String) -> String? {
        let lead = scope + "|"
        if let current, current.hasPrefix(lead) { return String(current.dropFirst(lead.count)) }
        if let editing, editing.hasPrefix(lead) { return String(editing.dropFirst(lead.count)) }
        return nil
    }
}

extension ChatViewController {
    /// Your answers still waiting behind a running reply (the queue): their cards show them as answered too.
    var askQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter { $0.hasPrefix(AskCards.markLead) } ?? []
    }

    /// The chat changed: a card whose answer arrived some other way than its own buttons (another device, the queue
    /// going out, delivery state update, or a queued answer taken back) is drawn again. Also dismisses any active
    /// "Answering: …" / "Editing Reply" composer strip if its target ask just got answered externally.
    func askMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = AskCards.answersByRow(messages, queued: askQueuedTexts)
        guard now != askAnswersShown else { return [] }
        let changed = Set(now.keys).union(askAnswersShown.keys).filter { now[$0] != askAnswersShown[$0] }
        askAnswersShown = now
        // Auto-dismiss an open composer strip if its ask was just answered from another device/queue.
        if let activeRow = AskAnswering.shared.activeRowId(in: scope), now[activeRow] != nil {
            (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        }
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part, call.name == AskCards.tool, AskCards.parse(call) != nil else { return false }
                return changed.contains(AskCards.rowId(messageId: m.id, callId: call.id))
            }
        }.map(\.id)
    }

    // MARK: ChatPromptCellHandling

    func askCardToggle(rowId: String, key: String) {
        toggleExpandedKey(key, forRowId: rowId)
    }

    func askCard(_ card: AskCardRow, chose index: Int) {
        guard card.answerable else { return }
        // [asks v2] A choice with a ready reply toggles its inline accordion preview (nothing sent yet).
        if AskCards.reply(card.ask, index: index) != nil {
            let next: Int? = card.picked == index ? nil : index
            AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) \(next == nil ? "unpicked" : "picked \(index + 1)") \(logTag)")
            Haptics.play(.selection)
            AskAnswering.shared.pick(next, scope: scope, rowId: card.rowId)
            holdRowIfNeeded(card.rowId)
            rebuildMessage(card.messageId)
            return
        }
        guard let text = AskCards.choiceMessage(card.ask, index: index) else { return }
        AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) choice \(index + 1) \(logTag)")
        Haptics.play(.selection)
        answerAsk(card, text)
    }

    /// [asks v2] Send under the inline ready reply answers with the choice and reply (your edits included); Edit puts
    /// the reply in the message field under an "Editing Reply" strip.
    func askCardReply(_ card: AskCardRow, tapped button: DraftButton) {
        guard card.answerable, let index = card.picked, let reply = card.reply else { return }
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
            AskAnswering.shared.setReply(text, scope: self.scope, rowId: card.rowId, ask: card.ask, index: index)
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
        composer.editingQueued = true
        composer.text = reply
        sendOverride = { text in
            if !text.isEmpty { save(text) }
            return true
        }
        AskAnswering.shared.setEditing(card.rowId, scope: scope)
        rebuildMessage(card.messageId)
        focusComposer()
    }

    func askCardOpen(_ card: AskCardRow) {
        guard let url = card.ask.link?.url else { return }
        AppLog.trace("asks", "ask \(AppLog.tag(card.ask.id)) link opened \(logTag)")
        LinkOpener.open(url, from: self)
    }

    /// "Something else…": clears any open v2 pick and opens a strip over the message field.
    func askCardOther(_ card: AskCardRow) {
        guard card.answerable else { return }
        (composer.editBanner as? ComposerEditBanner)?.onCancel?()
        if card.picked != nil {
            AskAnswering.shared.pick(nil, scope: scope, rowId: card.rowId)
        }
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
        AskAnswering.shared.set(card.rowId, scope: scope)
        rebuildMessage(card.messageId)
        focusComposer()
    }

    /// Your answer goes into the chat as a message of yours; keeps scroll position calm when answering an inline card
    /// above the fold (so multi-ask streams or expanded stale folds never yank the reader away).
    private func answerAsk(_ card: AskCardRow, _ text: String) {
        let shouldHold = !isScrolledToBottom
        if shouldHold { holdRowIfNeeded(card.rowId) }
        sendFromCard(text, display: text, scrollToBottom: !shouldHold)
        AskAnswering.shared.forget(scope: scope, rowId: card.rowId, ask: card.ask)
        rebuildMessage(card.messageId)
    }

    #if DEBUG
    /// `-HQDemoAskOther`: the newest ask card's "Something else…", as tapped (`-HQDemoAskOtherText <words>` types them).
    func debugAskOther(typing words: String?) {
        let input = AskAnswering.shared.rowsInput(session.messages, scope: scope)
        for m in session.messages.reversed() where m.role == .assistant {
            for case .tool(let call) in m.parts.reversed() {
                let rowId = AskCards.rowId(messageId: m.id, callId: call.id)
                guard let ask = AskCards.parse(call), input.rowAnswers?[rowId] == nil else { continue }
                let row = AskCardRow(ask: ask, rowId: rowId, messageId: m.id, answer: nil, answering: false)
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
                let rowId = AskCards.rowId(messageId: m.id, callId: call.id)
                guard let ask = AskCards.parse(call), input.rowAnswers?[rowId] == nil else { continue }
                let row = AskCardRow(ask: ask, rowId: rowId, messageId: m.id, answer: nil, answering: false)
                askCard(row, chose: n - 1)
                return
            }
        }
    }
    #endif
}
