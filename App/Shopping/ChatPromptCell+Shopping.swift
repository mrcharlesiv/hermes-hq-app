import UIKit

// [shopping] The prompt cell's side of the product cards and the order card: it hosts their views over the row, and
// passes their taps to the chat screen (ChatPromptCellHandling). The drawing is ProductCardsView / OrderCardButtons.

/// What a prompt cell keeps for shopping rows (made only when a shopping row is first drawn in the cell).
@MainActor struct ShoppingCellViews {
    var products: ProductCardsView?
    var orderButtons: OrderCardButtons?
    var productsRow: ProductsCardRow?
    var orderRow: OrderCardRow?
}

extension ChatPromptCell {
    func configureShopping(_ spec: PromptRow, _ l: PromptRowLayout) {
        switch (spec.kind, l.shopping) {
        case (.products(let row), .products(let g)?):
            let view = shoppingViews.products ?? makeProductsView()
            shoppingViews.productsRow = row
            view.isHidden = false
            view.frame = contentView.bounds
            view.configure(row, g)
            shoppingViews.orderButtons?.isHidden = true
            shoppingViews.orderRow = nil
        case (.order(let row), .order(let g)?):
            let buttons = shoppingViews.orderButtons ?? makeOrderButtons()
            shoppingViews.orderRow = row
            buttons.isHidden = false
            buttons.frame = contentView.bounds
            buttons.configure(g)
            shoppingViews.products?.isHidden = true
            shoppingViews.productsRow = nil
        default:
            shoppingViews.products?.isHidden = true
            shoppingViews.orderButtons?.isHidden = true
            shoppingViews.productsRow = nil
            shoppingViews.orderRow = nil
        }
    }

    /// VoiceOver's order for a shopping row; nil for any other row.
    func shoppingAccessibility(card: UIView) -> [Any]? {
        if shoppingViews.productsRow != nil, let view = shoppingViews.products { return [view] }
        if shoppingViews.orderRow != nil, let buttons = shoppingViews.orderButtons {
            card.accessibilityIdentifier = "order.card"
            return [card] + buttons.ordered
        }
        return nil
    }

    func resetShopping() {
        shoppingViews.products?.reset()
        shoppingViews.productsRow = nil
        shoppingViews.orderRow = nil
    }

    private func makeProductsView() -> ProductCardsView {
        let view = ProductCardsView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.onOpen = { [weak self] index in
            guard let self, let row = self.shoppingViews.productsRow else { return }
            self.handler?.shoppingOpen(row, index: index)
        }
        view.onAsk = { [weak self] index, ask in
            guard let self, let row = self.shoppingViews.productsRow else { return }
            self.handler?.shoppingAsk(row, index: index, ask: ask)
        }
        view.onFollowUp = { [weak self] text in
            guard let self, let row = self.shoppingViews.productsRow else { return }
            self.handler?.shoppingFollowUp(row, text: text)
        }
        view.onToggle = { [weak self] in
            guard let self, let row = self.shoppingViews.productsRow else { return }
            self.handler?.draftCardToggle(rowId: row.rowId)   // the chat's own Show All toggle (`expanded`)
        }
        contentView.addSubview(view)
        shoppingViews.products = view
        return view
    }

    private func makeOrderButtons() -> OrderCardButtons {
        let buttons = OrderCardButtons()
        buttons.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        buttons.onTap = { [weak self] answer in
            guard let self, let row = self.shoppingViews.orderRow, row.state == .waiting else { return }
            self.handler?.orderCard(row, tapped: answer)
        }
        buttons.onOpenItem = { [weak self] index in
            guard let self, let row = self.shoppingViews.orderRow else { return }
            self.handler?.orderCard(row, openedItem: index)
        }
        contentView.addSubview(buttons)
        shoppingViews.orderButtons = buttons
        return buttons
    }
}
