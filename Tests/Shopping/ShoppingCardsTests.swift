// [shopping] A bot's product cards and order card (HermesKit/Shopping/ShoppingCards.swift, App/Shopping): the ids the
// add-on makes too, lenient parsing, the answer messages and their bubble words, the states read back from the
// chat, the rows, their layouts, whole arguments and the add-on handshake.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Shopping: product cards, the order card and their answers")
struct ShoppingCardsTests {
    let us = Locale(identifier: "en_US")

    func product(_ title: String = "Trail Runner 2", store: String? = "Example Outfitters", url: String? = "https://example.com/p/trail-runner-2",
                 price: JSONValue? = .number(129.99), extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["title": .string(title)]
        if let store { o["store"] = .string(store) }
        if let url { o["url"] = .string(url) }
        if let price { o["price"] = price }
        o.merge(extra) { _, new in new }
        return .object(o)
    }

    func call(_ args: [String: JSONValue], name: String = ShoppingCards.productsTool, id: String = "c1",
              state: ToolCall.State = .done) -> ToolCall {
        ToolCall(id: id, name: name, title: name, argsText: ChatJSON.stringify(.object(args)), summary: nil, state: state, durationSeconds: nil)
    }

    func productsCall(_ products: [JSONValue], extra: [String: JSONValue] = [:], id: String = "c1") -> ToolCall {
        var args: [String: JSONValue] = ["products": .array(products)]
        args.merge(extra) { _, new in new }
        return call(args, id: id)
    }

    var orderArgs: [String: JSONValue] {
        ["store": .string("Example Outfitters"), "total": .number(140.39), "currency": .string("USD"),
         "items": .array([.object(["title": .string("Trail Runner 2"), "detail": .string("Navy, 10"), "qty": .number(1), "price": .number(129.99)]),
                          .object(["title": .string("Wool Socks"), "qty": .number(2)])]),
         "charges": .array([.object(["label": .string("Shipping"), "amount": .number(0)]), .object(["label": .string("Tax"), "amount": .number(10.4)])]),
         "ship_to": .object(["name": .string("Wren Example"), "address": .string("1 Demo Street")]),
         "pay_with": .string("Visa ending 4242"), "arrives": .string("Fri, Nov 20")]
    }

    func orderCall(_ args: [String: JSONValue]? = nil, id: String = "o1") -> ToolCall {
        call(args ?? orderArgs, name: ShoppingCards.orderTool, id: id)
    }

    func bot(_ calls: [ToolCall], id: String = "m1") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: calls.map { .tool($0) } + [.text("Here you go.")], timestamp: nil, rowId: 1)
    }

    func you(_ text: String, id: String = "u1") -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: nil, rowId: 2)
    }

    func input(_ messages: [ChatMessage], expanded: Set<String> = []) -> ChatRowBuilder.Input {
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: expanded, now: Date(),
                                         scope: "t", modelName: nil, prompts: nil)
        input.shopping = ShoppingCards.answers(messages)
        return input
    }

    func runner() throws -> ShoppingCards.Product {
        try #require(ShoppingCards.products(productsCall([product()]))?.products.first)
    }

    func order() throws -> ShoppingCards.Order { try #require(ShoppingCards.order(orderCall())) }

    // MARK: Ids (the add-on's Python checks against these)

    @Test func theIdsAreTheAddOnsOwn() throws {
        // Vectors for hermes-hq-push: SHA-256 over "Trail Runner 2\nExample Outfitters\nhttps://example.com/p/trail-runner-2"
        // and over "Example Outfitters\n140.39\nUSD\n1 x Trail Runner 2\n2 x Wool Socks", first 8 hex digits.
        #expect(ShoppingCards.productId(title: "Trail Runner 2", store: "Example Outfitters", url: "https://example.com/p/trail-runner-2") == "p-d6dc20a2")
        #expect(ShoppingCards.productId(title: "  Trail Runner 2\n", store: "Example Outfitters ", url: " https://example.com/p/trail-runner-2") == "p-d6dc20a2")
        #expect(try runner().id == "p-d6dc20a2")
        let items = [ShoppingCards.Item(title: "Trail Runner 2", detail: "", qty: 1, price: nil, image: nil),
                     ShoppingCards.Item(title: "Wool Socks", detail: "", qty: 2, price: nil, image: nil)]
        #expect(ShoppingCards.orderId(store: "Example Outfitters", total: 140.39, currency: "USD", items: items) == "o-4a928c2e")
        #expect(try order().id == "o-4a928c2e")
        // A changed total is a new order (the bot shows a new card for it).
        #expect(ShoppingCards.orderId(store: "Example Outfitters", total: 140.4, currency: "USD", items: items) != "o-4a928c2e")
    }

    // MARK: Parsing

    @Test func aWholeProductIsRead() throws {
        let full = product(extra: [
            "currency": .string("EUR"), "was": .number(159.99), "image": .string("https://example.com/a.jpg"),
            "images": .array([.string("https://example.com/b.jpg"), .string("https://example.com/a.jpg"), .string("http://example.com/c.jpg")]),
            "brand": .string("Otto Sports"), "rating": .number(4.6), "reviews": .number(1234), "badge": .string("Best value"),
            "stock": .string("preorder"), "delivery": .string("Free shipping"),
            "why": .array([.string("Wide toe box")]), "caution": .array([.string("Runs small")]),
            "options": .array([.object(["name": .string("Colour"), "value": .string("Navy")])]),
            "specs": .array([.object(["label": .string("Weight"), "value": .string("280 g")])]),
            "offers": .array([.object(["store": .string("Demo Goods"), "url": .string("https://example.com/d"), "price": .number(134)]),
                              .object(["store": .string("No Link")])]),
        ])
        let made = try #require(ShoppingCards.products(productsCall([full], extra: ["note": .string("This one."),
                                                                                   "follow_ups": .array([.string("Cheaper"), .number(3)])])))
        #expect(made.note == "This one.")
        #expect(made.followUps == ["Cheaper"])
        let p = try #require(made.products.first)
        #expect(p.currency == "EUR" && p.price == 129.99 && p.was == 159.99)
        #expect(p.images.map(\.absoluteString) == ["https://example.com/a.jpg", "https://example.com/b.jpg"])   // https only, once each
        #expect(p.brand == "Otto Sports" && p.badge == "Best value" && p.stock == .preorder && p.delivery == "Free shipping")
        #expect(p.rating == 4.6 && p.reviews == 1234)
        #expect(p.why == ["Wide toe box"] && p.caution == ["Runs small"])
        #expect(p.options == [ShoppingCards.Option(name: "Colour", value: "Navy")])
        #expect(p.specs == [ShoppingCards.Spec(label: "Weight", value: "280 g")])
        #expect(p.offers.map(\.store) == ["Demo Goods"])
        #expect(p.buyable)
    }

    @Test func aPartProductKeepsWhatItHas() throws {
        let made = try #require(ShoppingCards.products(productsCall([
            product("No Store", store: nil),
            product("No Link", url: nil),
            product("Plain Link", url: "http://example.com/x"),
            product("Gone", price: nil, extra: ["stock": .string("out")]),
            product("Odd Was", extra: ["was": .number(100), "currency": .string("dollars"), "stock": .string("maybe")]),
        ])))
        #expect(made.products.map(\.title) == ["Gone", "Odd Was"])
        let gone = made.products[0]
        #expect(gone.price == nil && gone.stock == .out && !gone.buyable)
        #expect(ShoppingCards.priceText(gone) == nil)
        let odd = made.products[1]
        #expect(odd.was == nil)                // a "was" not above the price is left out
        #expect(odd.currency == "USD")         // not a code: the default
        #expect(odd.stock == .inStock)
        // Nothing usable: no card.
        #expect(ShoppingCards.products(productsCall([product(store: nil)])) == nil)
        #expect(ShoppingCards.products(productsCall([])) == nil)
    }

    @Test func countsAndLengthsAreCut() throws {
        let many = (1...15).map { product("Item \($0)", url: "https://example.com/\($0)") }
        let made = try #require(ShoppingCards.products(productsCall(many, extra: ["follow_ups": .array((1...5).map { .string("F\($0)") })])))
        #expect(made.products.count == 12)
        #expect(made.followUps.count == 3)
        let long = String(repeating: "x", count: 300)
        let p = try #require(ShoppingCards.products(productsCall([product(long, extra: [
            "why": .array((1...6).map { .string("Reason \($0)") }), "badge": .string(String(repeating: "b", count: 40)),
        ])]))?.products.first)
        #expect(p.title.count == 160 && p.title.hasSuffix("…"))
        #expect(p.why.count == 3)
        #expect(p.badge.count == 24)
        #expect(p.id == ShoppingCards.productId(title: long, store: "Example Outfitters", url: "https://example.com/p/trail-runner-2"))   // made from the whole title
    }

    @Test func hostileArgumentsNeverCrash() throws {
        let weird = productsCall([
            .string("not an object"), .null, .number(4),
            product(extra: ["price": .string("$129.99"), "rating": .number(9), "reviews": .number(-3), "images": .string("https://example.com/a.jpg"),
                            "why": .string("one reason"), "options": .array([.string("Navy"), .object(["name": .number(1)])]),
                            "offers": .object(["store": .string("x")]), "stock": .array([])]),
        ])
        let p = try #require(ShoppingCards.products(weird)?.products.first)
        #expect(p.price == nil)          // a price with a symbol is not a number
        #expect(p.rating == 5)           // clamped to 0…5
        #expect(p.reviews == nil)
        #expect(p.images.isEmpty)
        #expect(p.why == ["one reason"])
        #expect(p.options.isEmpty && p.offers.isEmpty)
        #expect(ShoppingCards.products(call(["products": .string("nope")])) == nil)
        #expect(ShoppingCards.products(call(["products": .array([product()])], name: "send_message")) == nil)
        #expect(ShoppingCards.products(call(["products": .array([product()])], state: .failed)) == nil)
        var cut = productsCall([product()])
        cut.argsText = String(cut.argsText!.prefix(30))   // a cached transcript's clip
        #expect(ShoppingCards.products(cut) == nil)
        cut.argsText = nil
        #expect(ShoppingCards.products(cut) == nil)
        #expect(ShoppingCards.order(call(["store": .number(1), "total": .string("x")], name: ShoppingCards.orderTool)) == nil)
    }

    @Test func anOrderIsRead() throws {
        let o = try order()
        #expect(o.store == "Example Outfitters" && o.total == 140.39 && o.currency == "USD")
        #expect(o.items.map(\.qty) == [1, 2] && o.items[0].detail == "Navy, 10" && o.items[1].price == nil)
        #expect(o.charges == [ShoppingCards.Charge(label: "Shipping", amount: 0), ShoppingCards.Charge(label: "Tax", amount: 10.4)])
        #expect(o.shipName == "Wren Example" && o.payWith == "Visa ending 4242" && o.arrives == "Fri, Nov 20")
        var args = orderArgs
        args["items"] = .array([.object(["title": .string("  ")]), .object(["qty": .number(1)])])
        #expect(ShoppingCards.order(orderCall(args)) == nil)   // no item with a title
        args = orderArgs
        args["total"] = nil
        #expect(ShoppingCards.order(orderCall(args)) == nil)
        args = orderArgs
        args["items"] = .array([.object(["title": .string("Thing"), "qty": .number(-4)]), .object(["title": .string("Lots"), "qty": .string("5000")])])
        #expect(ShoppingCards.order(orderCall(args))?.items.map(\.qty) == [1, 999])
    }

    // MARK: Words

    @Test func pricesAndRatingsRead() throws {
        #expect(ShoppingCards.price(129.99, currency: "USD", locale: us) == "$129.99")
        #expect(ShoppingCards.price(1234.5, currency: "USD", locale: us) == "$1,234.50")
        #expect(ShoppingCards.price(20, currency: "EUR", locale: us) == "€20.00")
        #expect(ShoppingCards.ratingText(4.6, reviews: 1234, locale: us) == "4.6 (1,234)")
        #expect(ShoppingCards.ratingText(4, reviews: nil, locale: us) == "4.0")
        #expect(ShoppingCards.ratingText(nil, reviews: 12, locale: us) == nil)
        let p = try #require(ShoppingCards.products(productsCall([product(extra: ["was": .number(159.99)])]))?.products.first)
        #expect(ShoppingCards.wasText(p, locale: us) == "$159.99")
        #expect(ShoppingCards.wasText(try runner(), locale: us) == nil)
    }

    @Test func theAnswersAreTheSpecsMessages() throws {
        var p = try runner()
        #expect(ShoppingCards.buyMessage(p) == """
            [Hermes HQ shopping p-d6dc20a2: buy]
            Buy this for me: Trail Runner 2 from Example Outfitters for $129.99.
            https://example.com/p/trail-runner-2
            Check the price and that it is in stock, take it to the last step of checkout, then show me the order with order_card and wait for my answer before you pay.
            """)
        p.options = [.init(name: "Colour", value: "Navy"), .init(name: "Size", value: "10")]
        #expect(ShoppingCards.buyMessage(p).contains("\nBuy this for me: Trail Runner 2 (Colour: Navy, Size: 10) from Example Outfitters for $129.99.\n"))
        #expect(ShoppingCards.watchStockMessage(p) == """
            [Hermes HQ shopping p-d6dc20a2: watch stock]
            Tell me when this is back in stock: Trail Runner 2 (Colour: Navy, Size: 10) at Example Outfitters.
            https://example.com/p/trail-runner-2
            Set up a scheduled job that checks every 6 hours (use your price watch job if you have one) and tells me only when it is available.
            """)
        #expect(ShoppingCards.watchPriceMessage(p) == """
            [Hermes HQ shopping p-d6dc20a2: watch price]
            Tell me when the price of this drops below $129.99: Trail Runner 2 at Example Outfitters.
            https://example.com/p/trail-runner-2
            Set up a scheduled job that checks every 6 hours (use your price watch job if you have one) and tells me only when it drops.
            """)
        p.price = nil
        #expect(ShoppingCards.watchPriceMessage(p) == nil)
        #expect(!ShoppingCards.buyMessage(p).contains(" for $"))
        let o = try order()
        #expect(ShoppingCards.payMessage(o) == "[Hermes HQ order o-4a928c2e: pay]\nPlace this order now: Example Outfitters, total $140.39. "
            + "Pay exactly this total. If the total on the page is different now, stop and show me a new order card.")
        #expect(ShoppingCards.cancelMessage(o) == "[Hermes HQ order o-4a928c2e: cancel]\nDon't place this order. Nothing should be charged.")
    }

    @Test func yourBubbleReadsShort() throws {
        var p = try runner()
        p.title = "Gift from the Hills"   // a title holding " from " and " at "-like words
        p.options = [.init(name: "Colour", value: "Navy")]
        #expect(ShoppingCards.bubbleWords(ShoppingCards.buyMessage(try runner())) == "Buy: Trail Runner 2")
        #expect(ShoppingCards.bubbleWords(ShoppingCards.buyMessage(p)) == "Buy: Gift from the Hills (Colour: Navy)")
        #expect(ShoppingCards.bubbleWords(ShoppingCards.watchStockMessage(try runner())) == "Notify me: Trail Runner 2")
        #expect(ShoppingCards.bubbleWords(ShoppingCards.watchPriceMessage(try runner())!) == "Notify me of a price drop: Trail Runner 2")
        #expect(ShoppingCards.bubbleWords(ShoppingCards.payMessage(try order())) == "Pay $140.39")
        #expect(ShoppingCards.bubbleWords(ShoppingCards.cancelMessage(try order())) == "Cancel order")
        #expect(ShoppingCards.bubbleWords("Buy this for me: a thing") == nil)
        #expect(ShoppingCards.bubbleWords("Please [Hermes HQ order o-4a928c2e: pay]") == nil)   // only a first line is an answer
        #expect(ShoppingCards.bubbleWords("[Hermes HQ shopping p-d6dc20a2: buy]") == "Buy")
        // The queue shows the same short words, and a chat bubble too.
        let waiting = ShoppingCards.payMessage(try order())
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "q1", text: waiting, display: waiting)).text == "Pay $140.39")
        let rows = ChatRowBuilder.build(input([bot([orderCall()]), you(waiting)]))
        #expect(rows.contains { if case .bubble(let b) = $0.kind { return b.mine && b.text == "Pay $140.39" } else { return false } })
    }

    // MARK: Read back from the chat

    @Test func anOrderCardsStateIsReadFromTheChat() throws {
        let o = try order()
        let card = bot([orderCall()])
        #expect(ShoppingCards.answers([card]).orderStates == ["o1": .waiting])
        #expect(ShoppingCards.answers([card, you(ShoppingCards.payMessage(o))]).orderStates == ["o1": .approved])
        #expect(ShoppingCards.answers([card, you(ShoppingCards.cancelMessage(o))]).orderStates == ["o1": .cancelled])
        // A newer order card replaces an older one left waiting; an answered one keeps its answer.
        var newer = orderArgs
        newer["total"] = .number(145.79)
        let second = bot([orderCall(newer, id: "o2")], id: "m2")
        #expect(ShoppingCards.answers([card, second]).orderStates == ["o1": .replaced, "o2": .waiting])
        #expect(ShoppingCards.answers([card, you(ShoppingCards.cancelMessage(o)), second]).orderStates == ["o1": .cancelled, "o2": .waiting])
        // Your answer still waiting behind a running reply counts.
        #expect(ShoppingCards.answers([card], queued: [ShoppingCards.payMessage(o)]).orderStates == ["o1": .approved])
        #expect(ShoppingCards.status(.approved, o, locale: us) == "You approved $140.39")
        #expect(ShoppingCards.status(.cancelled, o) == "Cancelled. Nothing was charged.")
        #expect(ShoppingCards.status(.replaced, o) == "A newer order replaced this one")
        #expect(ShoppingCards.status(.waiting, o) == nil)
    }

    @Test func aProductsAsksAreReadFromTheChat() throws {
        let p = try runner()
        let card = bot([productsCall([product()])])
        #expect(ShoppingCards.answers([card]).asked.isEmpty)
        let asked = ShoppingCards.answers([card, you(ShoppingCards.buyMessage(p)), you(ShoppingCards.watchPriceMessage(p)!, id: "u2")]).asked
        #expect(asked == [p.id: [.buy, .watchPrice]])
        #expect(ShoppingCards.askedText([.buy, .watchPrice]) == "Asked to buy")
        #expect(ShoppingCards.askedText([.watchStock]) == "Watching")
        #expect(ShoppingCards.askedText([]) == nil)
        #expect(ShoppingCards.answers([card], queued: [ShoppingCards.watchStockMessage(p)]).asked == [p.id: [.watchStock]])
        // A bot's own words that look like an answer are not one.
        let botSays = ChatMessage(id: "m9", role: .assistant, parts: [.text(ShoppingCards.buyMessage(p))], timestamp: nil, rowId: 9)
        #expect(ShoppingCards.answers([botSays]).asked.isEmpty)
    }

    // MARK: Rows

    @Test func theChatDrawsTheCardsInsteadOfSteps() throws {
        let rows = ChatRowBuilder.build(input([bot([productsCall([product()]), orderCall()])]))
        let kinds = rows.compactMap { row -> String? in
            guard case .prompt(let p) = row.kind else { return nil }
            switch p.kind {
            case .products: return "products"
            case .order: return "order"
            default: return nil
            }
        }
        #expect(kinds == ["products", "order"])
        #expect(!rows.contains { if case .toolRun = $0.kind { return true } else { return false } })
        // A failed call is the plain step it is.
        let failed = ChatRowBuilder.build(input([bot([call(["products": .array([product()])], state: .failed)])]))
        #expect(!failed.contains { if case .prompt = $0.kind { return true } else { return false } })
    }

    func productsRow(_ messages: [ChatMessage], expanded: Set<String> = []) -> (ChatRow, ProductsCardRow)? {
        for row in ChatRowBuilder.build(input(messages, expanded: expanded)) {
            if case .prompt(let p) = row.kind, case .products(let card) = p.kind { return (row, card) }
        }
        return nil
    }

    func orderRow(_ messages: [ChatMessage]) -> (ChatRow, OrderCardRow)? {
        for row in ChatRowBuilder.build(input(messages)) {
            if case .prompt(let p) = row.kind, case .order(let card) = p.kind { return (row, card) }
        }
        return nil
    }

    @Test func aRowChangesOnlyWithItsContentOrState() throws {
        let p = try runner()
        let card = bot([productsCall([product()])])
        let (before, plain) = try #require(productsRow([card]))
        let (same, _) = try #require(productsRow([card, you("Thanks", id: "u5")]))
        #expect(before.fingerprint == same.fingerprint)
        let (after, asked) = try #require(productsRow([card, you(ShoppingCards.buyMessage(p))]))
        #expect(plain.asked.isEmpty && asked.asks(p) == [.buy])
        #expect(before.fingerprint != after.fingerprint)
        let (waiting, w) = try #require(orderRow([bot([orderCall()])]))
        let (approved, a) = try #require(orderRow([bot([orderCall()]), you(ShoppingCards.payMessage(try order()))]))
        #expect(w.state == .waiting && a.state == .approved)
        #expect(waiting.fingerprint != approved.fingerprint)
    }

    // MARK: Layout

    @Test func theCountPicksTheLayout() {
        #expect(ProductCardsLayout.mode(1) == .single)
        #expect(ProductCardsLayout.mode(2) == .pair)
        #expect(ProductCardsLayout.mode(3) == .row && ProductCardsLayout.mode(8) == .row)
        #expect(ProductCardsLayout.mode(9) == .list && ProductCardsLayout.mode(12) == .list)
    }

    /// A finger's tap on a card (what a touch sends a plain UIControl) opens that product's page, in every layout.
    /// Build 1084 listened for an event only buttons send, so no card could be opened.
    @Test func aTapOnACardOpensItsProduct() throws {
        for count in [1, 2, 5, 12] {
            let items = (0..<count).map { product("Item \($0)", url: "https://example.com/p/\($0)") }
            let (_, card) = try #require(productsRow([bot([productsCall(items)])]))
            let g = ProductCardsLayout.geometry(card, gap: 6, width: 402, category: .large)
            let view = ProductCardsView(frame: CGRect(x: 0, y: 0, width: 402, height: 900))
            var opened: [Int] = []
            view.onOpen = { opened.append($0) }
            view.configure(card, g)
            func cards(_ v: UIView) -> [ProductCardView] { v.subviews.flatMap { ($0 as? ProductCardView).map { [$0] } ?? cards($0) } }
            let shown = cards(view).filter { !$0.isHidden }
            #expect(shown.count == g.cards.count, "\(count) products")
            for c in shown { c.sendActions(for: .touchUpInside) }
            #expect(opened.sorted() == Array(0..<g.cards.count), "\(count) products")
            // The touch lands on the card itself, not on a label or the photo over it.
            if let first = shown.first {
                let hit = first.hitTest(CGPoint(x: first.bounds.midX, y: 12), with: nil)
                #expect(hit === first, "\(count) products: \(String(describing: hit))")
            }
        }
    }

    @Test func oneProductHasItsBuyButtonInsideTheCard() throws {
        let (_, card) = try #require(productsRow([bot([productsCall([product()])])]))
        let g = ProductCardsLayout.geometry(card, gap: 6, width: 402, category: .large)
        #expect(g.mode == .single && g.cards.count == 1)
        let parts = ProductCardsLayout.parts(g, size: g.cards[0].size)
        let button = try #require(parts.button)
        #expect(CGRect(origin: .zero, size: g.cards[0].size).contains(button))
        #expect(ProductCardsLayout.buttonTitle(try runner(), asks: []).title == "Buy")
        #expect(ProductCardsLayout.buttonTitle(try runner(), asks: [.buy]) == ("Asked to buy", .buy, true))
    }

    @Test func aLongListShowsFiveThenSeeAll() throws {
        let twelve = (1...12).map { product("Item \($0)", url: "https://example.com/\($0)") }
        let message = bot([productsCall(twelve)])
        let (_, short) = try #require(productsRow([message]))
        let g = ProductCardsLayout.geometry(short, gap: 6, width: 402, category: .large)
        #expect(g.mode == .list && g.cards.count == 5 && g.seeAll?.title == "7 more ›")
        let (_, open) = try #require(productsRow([message], expanded: [short.rowId]))
        let all = ProductCardsLayout.geometry(open, gap: 6, width: 402, category: .large)
        #expect(all.cards.count == 12 && all.seeAll?.title == "Show Less")
        #expect(ProductCardsLayout.make(open, gap: 6, width: 402, category: .large).height
                > ProductCardsLayout.make(short, gap: 6, width: 402, category: .large).height)
        // Five scroll sideways, in a strip as wide as the row.
        let (_, five) = try #require(productsRow([bot([productsCall(Array(twelve.prefix(5)))])]))
        let row = ProductCardsLayout.geometry(five, gap: 6, width: 402, category: .large)
        #expect(row.mode == .row && row.cards.count == 5 && row.stripContent > 402 && row.strip?.width == 402)
    }

    /// A card's words never end in "…" on a 375 pt phone: the rating moves to the store line, or leaves the card (the
    /// page has it, with the count of reviews), before the price or the store would be cut.
    @Test func cardWordsFitWithoutAnEllipsis() throws {
        let rated: [String: JSONValue] = ["was": .number(79.99), "rating": .number(4.4), "reviews": .number(201)]
        let five = (1...5).map { product("Item \($0)", store: "Example Outfitters", url: "https://example.com/\($0)",
                                         price: .number(64.99), extra: rated) }
        let twelve = (1...12).map { product("Item \($0)", store: $0 == 2 ? "Example Outfitters" : "Demo Goods",
                                            url: "https://example.com/\($0)", price: .number(13.75),
                                            extra: rated.merging(["stock": .string($0 == 3 ? "out" : "in")]) { _, new in new }) }
        for products in [five, twelve, Array(five.prefix(2)), [five[0]]] {
            let (_, card) = try #require(productsRow([bot([productsCall(products)])]))
            let g = ProductCardsLayout.geometry(card, gap: 6, width: 375, category: .large)
            for (i, frame) in g.cards.enumerated() {
                let parts = ProductCardsLayout.parts(g, size: frame.size, product: card.products.products[i])
                #expect(ProductCardsLayout.measure(parts.priceText) <= parts.price.width + 0.5, "price line, \(g.mode)")
                if g.mode != .list { #expect(ProductCardsLayout.measure(parts.metaText) <= parts.meta.width + 0.5, "store, \(g.mode)") }
                #expect(!parts.ratingText.string.contains("("), "the count of reviews is on the page")
                if let rating = parts.rating {
                    #expect(!rating.intersects(parts.price) && !rating.intersects(parts.meta), "the rating overlaps, \(g.mode)")
                }
                if let button = parts.button { #expect(!button.intersects(parts.meta), "Buy over the store") }
            }
        }
        // The struck old price in a list row: no space before or after it, so its strike can't run into its neighbours.
        let (_, list) = try #require(productsRow([bot([productsCall(twelve)])]))
        let line = ProductCardsLayout.listLine(list.products.products[0], ProductFonts(.large)).string
        #expect(line.contains("$79.99") && !line.contains(" $79.99") && !line.contains("$79.99 "))
    }

    @Test func aWaitingOrderHasCancelAndPayInsideIt() throws {
        let (_, card) = try #require(orderRow([bot([orderCall()])]))
        let made = OrderCardLayout.make(card, gap: 6, width: 402, category: .large)
        guard case .prompt(let layout) = made.content, case .order(let g)? = layout.shopping else { Issue.record("layout"); return }
        #expect(g.buttons.map(\.0) == [.pay, .cancel])   // placed from the trailing edge: Pay is rightmost
        #expect(g.payTitle == OrderCardLayout.payTitle(card.order))
        let frame = try #require(layout.cardFrame)
        #expect(g.buttons.allSatisfy { frame.contains($0.1) && $0.1.height >= 44 })
        #expect(layout.accessibility.contains("Order at Example Outfitters") && layout.accessibility.contains("Total"))

        let (_, done) = try #require(orderRow([bot([orderCall()]), you(ShoppingCards.cancelMessage(try order()))]))
        let settled = OrderCardLayout.make(done, gap: 6, width: 402, category: .large)
        guard case .prompt(let s) = settled.content, case .order(let sg)? = s.shopping else { Issue.record("settled"); return }
        #expect(sg.buttons.isEmpty)
        #expect(s.accessibility.hasSuffix("Cancelled. Nothing was charged."))
    }

    // MARK: Whole arguments and the add-on

    @Test func shoppingCallsKeepTheirWholeArguments() throws {
        let long = String(repeating: "A reason that runs on. ", count: 400)
        let args: [String: JSONValue] = ["products": .array([product(extra: ["why": .array([.string(long)])])])]
        let whole = try #require(ShoppingCards.wholeArgsText(name: ShoppingCards.productsTool, args: args))
        #expect(whole.utf8.count > 4096)
        #expect(ShoppingCards.wholeArgsText(name: ShoppingCards.orderTool, args: orderArgs) != nil)
        #expect(ShoppingCards.wholeArgsText(name: "web_search", args: args) == nil)
        #expect(ShoppingCards.wholeArgsText(name: ShoppingCards.productsTool, args: [:]) == nil)
        // A saved chat keeps them (cut, the card would draw as a plain step).
        var plain = call(args, name: "web_search", id: "c2")
        plain.argsText = whole
        let message = ChatMessage(id: "m1", role: .assistant, parts: [.tool(call(args)), .tool(plain)], timestamp: nil, rowId: 1)
        let kept = TranscriptCache.withoutToolDetails(TranscriptEntry(messages: [message], meta: [:], savedAt: Date()))
        guard case .tool(let cards) = kept.messages[0].parts[0], case .tool(let other) = kept.messages[0].parts[1] else { Issue.record("parts"); return }
        #expect(ShoppingCards.products(cards) != nil)
        #expect((other.argsText?.utf8.count ?? 0) < 600)
    }

    @Test func theAddOnIsToldOnceItOffersTheTools() {
        #expect(ShoppingCards.cardsUntold(["shoppingCards": true, "shoppingCardsShown": false]))
        #expect(ShoppingCards.cardsUntold(["shoppingCards": true]))
        #expect(!ShoppingCards.cardsUntold(["shoppingCards": true, "shoppingCardsShown": true]))
        #expect(!ShoppingCards.cardsUntold(["shoppingCards": false]))
        #expect(!ShoppingCards.cardsUntold(["draftCards": true]))
        #expect(!ShoppingCards.cardsUntold(nil))
        #expect(ShoppingCards.cardsPath == "/shopping/cards")
        #expect(PushPolicy.shoppingCardsKnown(["shoppingCards": false]))
        #expect(!PushPolicy.shoppingCardsKnown(["draftCards": true]))
    }

    @Test func widePaneProductsCapToCardRailAndAvoidMidCardCutoff() throws {
        let wideWidth: CGFloat = 1000
        let cardW = PromptLayout.cardWidth(for: wideWidth)
        let twelve = (1...12).map { product("Item \($0)", url: "https://example.com/\($0)") }

        // Single, pair, and list cap cleanly to the card rail instead of stretching across the wide pane.
        let (_, singleRow) = try #require(productsRow([bot([productsCall(Array(twelve.prefix(1)))])]))
        let single = ProductCardsLayout.geometry(singleRow, gap: 6, width: wideWidth, category: .large)
        #expect(single.cards[0].width == cardW)

        let (_, pairRow) = try #require(productsRow([bot([productsCall(Array(twelve.prefix(2)))])]))
        let pair = ProductCardsLayout.geometry(pairRow, gap: 6, width: wideWidth, category: .large)
        #expect(pair.cards[1].maxX == ProductCardsLayout.side + cardW)
        #expect(pair.photo <= 200)

        let (_, listRow) = try #require(productsRow([bot([productsCall(twelve)])]))
        let list = ProductCardsLayout.geometry(listRow, gap: 6, width: wideWidth, category: .large)
        #expect(list.listCard?.width == cardW)

        // Row carousel on a Mac wide pane (wholeTiles: true) fits exact whole tiles inside the rail and clips cleanly.
        let (_, fiveRowA) = try #require(productsRow([bot([productsCall(Array(twelve.prefix(5)), id: "c-wide-a")], id: "m-wide-a")]))
        let (_, fiveRowB) = try #require(productsRow([bot([productsCall(Array(twelve.prefix(5)), id: "c-wide-b")], id: "m-wide-b")]))
        let macRow = ProductCardsLayout.geometry(fiveRowA, gap: 6, width: wideWidth, category: .large, wholeTiles: true)
        let carousel = try #require(macRow.carousel)
        let strip = try #require(macRow.strip)
        #expect(!carousel.bleeds && carousel.wholeTiles)
        #expect(strip.minX == ProductCardsLayout.side)
        #expect(strip.width <= cardW)
        let exactViewport = CGFloat(carousel.visibleColumns) * carousel.tileWidth
            + CGFloat(carousel.visibleColumns - 1) * carousel.spacing
        #expect(abs(strip.width - exactViewport) < 0.01)

        // Wide iPad pane (wholeTiles: false) stays inset on the rail and peeks the next product as a scroll cue.
        let ipadRow = ProductCardsLayout.geometry(fiveRowA, gap: 6, width: wideWidth, category: .large, wholeTiles: false)
        let ipadCarousel = try #require(ipadRow.carousel)
        #expect(!ipadCarousel.bleeds && !ipadCarousel.wholeTiles && ipadCarousel.isScrollable)

        // Scroll offset for row A survives cell reuse for row B and re-snaps cleanly.
        let view = ProductCardsView(frame: CGRect(x: 0, y: 0, width: wideWidth, height: 600))
        view.configure(fiveRowA, macRow)
        let scroll = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scroll.clipsToBounds)
        scroll.contentOffset.x = carousel.stride
        view.scrollViewDidScroll(scroll)
        view.configure(fiveRowB, macRow)
        #expect(abs(scroll.contentOffset.x) < 0.5)
        view.configure(fiveRowA, macRow)
        #expect(abs(scroll.contentOffset.x - carousel.stride) < 0.5)
    }
}
