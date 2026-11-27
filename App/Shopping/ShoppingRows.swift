import UIKit

// [shopping] The chat's rows for a bot's product cards and order card (docs/spec/3x-shopping.md §3): pure values,
// built and measured on any thread like the draft card's (App/Questions/PromptRows.swift). The drawing is in
// ProductCardsView.swift and OrderCardView.swift; the chat screen's side in ChatViewController+Shopping.swift.

/// A `show_products` call's row.
nonisolated struct ProductsCardRow: Sendable, Hashable {
    var products: ShoppingCards.Products
    var rowId: String
    var messageId: String
    /// What you already asked for each of its products (product id → asks), read from the chat.
    var asked: [String: Set<ShoppingCards.Ask>]
    /// A long list's See All was tapped.
    var expanded: Bool

    var count: Int { products.products.count }

    func asks(_ product: ShoppingCards.Product) -> Set<ShoppingCards.Ask> { asked[product.id] ?? [] }
}

/// An `order_card` call's row.
nonisolated struct OrderCardRow: Sendable, Hashable {
    var order: ShoppingCards.Order
    var rowId: String
    var messageId: String
    var state: ShoppingCards.OrderState
    /// Indices of `order.items` that can open a product page (direct URL, order site, or matched prior product).
    var openableItems: Set<Int> = []
}

/// The drawing a shopping row hands its cell (`PromptRowLayout.shopping`).
nonisolated enum ShoppingRowLayout: @unchecked Sendable {
    case products(ProductCardsGeometry)
    case order(OrderCardGeometry)
}

nonisolated extension PromptRows {
    /// A shopping tool part's row; nil when the call isn't one or can't be read (it draws as the step it is).
    static func shoppingRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        switch call.name {
        case ShoppingCards.productsTool:
            guard let products = ShoppingCards.products(call) else { return nil }
            let id = "\(message.id)|shop\(call.id)"
            var asked: [String: Set<ShoppingCards.Ask>] = [:]
            for p in products.products { if let a = input.shopping.asked[p.id] { asked[p.id] = a } }
            let card = ProductsCardRow(products: products, rowId: id, messageId: message.id, asked: asked,
                                       expanded: input.expanded.contains(id))
            return row(id: id, messageId: message.id, kind: .products(card), scope: input.scope)
        case ShoppingCards.orderTool:
            guard let order = ShoppingCards.order(call) else { return nil }
            let id = "\(message.id)|order\(call.id)"
            let history = ShoppingCards.catalogProducts(in: input.messages)
            let card = OrderCardRow(order: order, rowId: id, messageId: message.id,
                                    state: input.shopping.orderStates[call.id] ?? .waiting,
                                    openableItems: ShoppingCards.openableItemIndices(in: order, matching: history))
            return row(id: id, messageId: message.id, kind: .order(card), scope: input.scope)
        default:
            return nil
        }
    }
}
