import UIKit

// [asks] The prompt cell's side of the ask card: it hosts AskCardView over the row and passes its taps to the chat
// screen (ChatPromptCellHandling).

/// What a prompt cell keeps for ask rows (made only when an ask row is first drawn in the cell).
@MainActor struct AskCellViews {
    var view: AskCardView?
    var row: AskCardRow?
}

extension ChatPromptCell {
    func configureAsk(_ spec: PromptRow, _ l: PromptRowLayout) {
        guard case .ask(let row) = spec.kind, let g = l.ask else {
            askViews.view?.isHidden = true
            askViews.row = nil
            return
        }
        let view = askViews.view ?? makeAskView()
        askViews.row = row
        view.isHidden = false
        view.frame = contentView.bounds
        view.configure(g, cardFrame: l.cardFrame)
    }

    /// VoiceOver's order for an ask row; nil for any other row.
    func askAccessibility(card: UIView) -> [Any]? {
        guard let row = askViews.row, let view = askViews.view else { return nil }
        card.accessibilityIdentifier = "ask.card"
        if row.isQuietFolded || row.answer != nil {
            return view.ordered
        }
        return [card] + view.ordered
    }

    func resetAsk() { askViews.row = nil }

    private func makeAskView() -> AskCardView {
        let view = AskCardView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.onChoice = { [weak self] index in
            guard let self, let row = self.askViews.row, row.waiting, !row.answering, !row.editingReply else { return }
            self.handler?.askCard(row, chose: index)
        }
        view.onOther = { [weak self] in
            guard let self, let row = self.askViews.row, row.waiting, !row.answering, !row.editingReply else { return }
            self.handler?.askCardOther(row)
        }
        view.onLink = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            self.handler?.askCardOpen(row)
        }
        // [asks v2] The ready reply's Send and Edit; Show All opens a long one (as a draft card's).
        view.onReply = { [weak self] button in
            guard let self, let row = self.askViews.row, row.waiting, !row.answering, !row.editingReply, row.reply != nil else { return }
            self.handler?.askCardReply(row, tapped: button)
        }
        view.onShowAll = { [weak self] in
            guard let self, let row = self.askViews.row else { return }
            self.handler?.draftCardToggle(rowId: row.rowId)
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
