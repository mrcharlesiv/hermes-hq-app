import UIKit

// [shopping] The chat screen's side of the product cards and the order card (HermesKit/Shopping/ShoppingCards.swift):
// a card opens its product's page; Buy, Notify Me, Notify Me of a Price Drop, Pay, Cancel and a follow-up go into the
// chat as your message, as a draft card's Send does (`sendFromCard`), and the card is drawn again in its new state.

extension ChatViewController {
    /// Your answers still waiting behind a running reply (the queue): their cards show them as answered too.
    var shoppingQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter {
            $0.hasPrefix(ShoppingCards.productLead) || $0.hasPrefix(ShoppingCards.orderLead)
        } ?? []
    }

    /// The chat changed: a card whose state changed some other way than its own buttons (another device, the queue
    /// going out, a newer order card) is drawn again. Returns the messages to rebuild.
    func shoppingMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = ShoppingCards.answers(messages, queued: shoppingQueuedTexts)
        guard now != shoppingAnswersShown else { return [] }
        shoppingAnswersShown = now
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part else { return false }
                return ShoppingCards.tools.contains(call.name)
            }
        }.map(\.id)
    }

    // MARK: ChatPromptCellHandling

    func shoppingOpen(_ card: ProductsCardRow, index: Int) {
        guard card.products.products.indices.contains(index) else { return }
        let product = card.products.products[index]
        AppLog.trace("shopping", "product \(AppLog.tag(product.id)) opened \(logTag)")
        ProductPageSheet.present(product, asks: card.asks(product), from: self) { [weak self] ask in
            self?.shoppingAsk(card, index: index, ask: ask)
        }
    }

    func shoppingAsk(_ card: ProductsCardRow, index: Int, ask: ShoppingCards.Ask) {
        guard card.products.products.indices.contains(index) else { return }
        let product = card.products.products[index]
        guard !card.asks(product).contains(ask), let text = ShoppingCards.message(ask, product) else { return }
        AppLog.trace("shopping", "product \(AppLog.tag(product.id)) \(ask.rawValue) \(logTag)")
        Haptics.play(.selection)
        // `display` given: the words go out as they are (a task's chat wraps typed words; the mark must lead).
        sendFromCard(text, display: text)
        rebuildMessage(card.messageId)
    }

    func shoppingFollowUp(_ card: ProductsCardRow, text: String) {
        sendFromCard(text, display: text)
    }

    func orderCard(_ card: OrderCardRow, tapped answer: ShoppingCards.OrderAnswer) {
        guard card.state == .waiting else { return }
        AppLog.trace("shopping", "order \(AppLog.tag(card.order.id)) \(answer.rawValue) \(logTag)")
        Haptics.play(answer == .pay ? .success : .selection)
        let text = answer == .pay ? ShoppingCards.payMessage(card.order) : ShoppingCards.cancelMessage(card.order)
        sendFromCard(text, display: text)
        rebuildMessage(card.messageId)
    }

    func orderCard(_ card: OrderCardRow, openedItem index: Int) {
        guard card.order.items.indices.contains(index) else { return }
        let item = card.order.items[index]
        let history = ShoppingCards.catalogProducts(in: session.messages)
        guard let product = ShoppingCards.product(for: item, in: card.order, matching: history) else { return }
        let answers = ShoppingCards.answers(session.messages, queued: shoppingQueuedTexts)
        AppLog.trace("shopping", "order \(AppLog.tag(card.order.id)) opened item \(index) \(logTag)")
        Haptics.play(.selection)
        ProductPageSheet.present(product, asks: answers.asked[product.id] ?? [], from: self) { [weak self] ask in
            guard let self, let text = ShoppingCards.message(ask, product) else { return }
            Haptics.play(.selection)
            self.sendFromCard(text, display: text)
            self.rebuildMessage(card.messageId)
        }
    }

    #if DEBUG
    /// `-HQDemoShoppingOpen <n>`: the n-th product of the chat (1 = the first, counting every card) on its page;
    /// `-HQDemoShoppingBuy <n>`: its Buy, as tapped.
    func debugOpenProduct(_ n: Int, buy: Bool = false) {
        var seen = 0
        for m in session.messages where m.role == .assistant {
            for case .tool(let call) in m.parts {
                guard let products = ShoppingCards.products(call) else { continue }
                if n - seen <= products.products.count, n - seen >= 1 {
                    let row = ProductsCardRow(products: products, rowId: "", messageId: m.id, asked: [:], expanded: false)
                    let answers = ShoppingCards.answers(session.messages)
                    var card = row
                    for p in products.products { card.asked[p.id] = answers.asked[p.id] }
                    if buy { shoppingAsk(card, index: n - seen - 1, ask: .buy) } else { shoppingOpen(card, index: n - seen - 1) }
                    return
                }
                seen += products.products.count
            }
        }
    }
    #endif
}
