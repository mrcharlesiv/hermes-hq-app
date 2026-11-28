import UIKit

// [asks] The prompt cell's side of the ask card: hosts AskCardView over the row, forwards taps (including split
// quote/reply expansions and answerable stale folds), and supplies long-press context menu actions.

/// What a prompt cell keeps for ask rows (made only when an ask row is first drawn in the cell).
@MainActor struct AskCellViews {
    var view: AskCardView?
    var row: AskCardRow?
}

extension ChatPromptCell {
    func configureAsk(_ spec: PromptRow, _ l: PromptRowLayout) {
        guard case .ask(let row) = spec.kind, let g = l.ask else {
            askViews.view?.isHidden = true
            askViews.view?.cancelLoads()
            askViews.row = nil
            return
        }
        let view = askViews.view ?? makeAskView()
        askViews.row = row
        view.isHidden = false
        view.frame = contentView.bounds
        // Place interactive choice row backgrounds right above `card` and below every TextDrawView so drawn text
        // renders razor-sharp above highlight washes, tags, chips, and reply paper.
        contentView.insertSubview(view, aboveSubview: askHostCard)
        view.configure(g, cardFrame: l.cardFrame)
    }

    /// VoiceOver's order for an ask row; nil for any other row.
    func askAccessibility(card: UIView) -> [Any]? {
        guard let row = askViews.row, let view = askViews.view else { return nil }
        card.accessibilityIdentifier = "ask.card"
        if row.isQuietFolded || (row.answer != nil && !row.expanded) {
            return view.ordered
        }
        return [card] + view.ordered
    }

    /// Context menu actions for long-pressing an Ask card or receipt.
    func askContextMenu() -> UIMenu? {
        guard let row = askViews.row else { return nil }
        let ask = row.ask
        var actions: [UIAction] = [
            UIAction(title: "Copy Question", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = ask.question
                Haptics.play(.light)
            }
        ]
        if !ask.quote.isEmpty {
            actions.append(UIAction(title: "Copy Quote", image: UIImage(systemName: "text.quote")) { _ in
                UIPasteboard.general.string = ask.quote
                Haptics.play(.light)
            })
        }
        let copyableReply: String? = {
            if let r = row.reply, !r.isEmpty { return r }
            if case .sent(_, _, let r)? = row.answer, !r.isEmpty { return r }
            return nil
        }()
        if let reply = copyableReply {
            actions.append(UIAction(title: "Copy Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                UIPasteboard.general.string = reply
                Haptics.play(.light)
            })
        }
        if let link = ask.link {
            actions.append(UIAction(title: link.title, image: UIImage(systemName: "arrow.up.right")) { [weak self] _ in
                self?.handler?.askCardOpen(row)
            })
        }
        return UIMenu(children: actions)
    }

    func resetAsk() {
        askViews.view?.cancelLoads()
        askViews.row = nil
    }

    private func makeAskView() -> AskCardView {
        let view = AskCardView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.onChoice = { [weak self] index in
            guard let self, let row = self.askViews.row, row.answerable, !row.answering, !row.editingReply else { return }
            self.handler?.askCard(row, chose: index)
        }
        view.onOther = { [weak self] in
            guard let self, let row = self.askViews.row, row.answerable, !row.answering, !row.editingReply else { return }
            self.handler?.askCardOther(row)
        }
        view.onLink = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            self.handler?.askCardOpen(row)
        }
        view.onQuoteToggle = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            self.handler?.askCardToggle(rowId: row.rowId, key: AskRowsInput.quoteExpandKey(row.rowId))
        }
        view.onReply = { [weak self] button in
            guard let self, let row = self.askViews.row, row.answerable, !row.answering, !row.editingReply, row.reply != nil else { return }
            self.handler?.askCardReply(row, tapped: button)
        }
        view.onShowAll = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            self.handler?.askCardToggle(rowId: row.rowId, key: AskRowsInput.replyExpandKey(row.rowId))
        }
        view.onToggle = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            Haptics.play(.selection)
            self.handler?.draftCardToggle(rowId: row.rowId)
        }
        contentView.addSubview(view)
        askViews.view = view
        return view
    }
}
