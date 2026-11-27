// [shopping] Product cards and the order card (docs/spec/3x-shopping.md): two tools of the Hermes HQ add-on,
// `show_products` and `order_card`, whose arguments the app draws as cards, as it draws `draft_message` (DraftCards).
// The tools wait for nothing: the card is the tool call, and what the person taps goes back as an ordinary message
// whose first line names the product or the order:
//
//     [Hermes HQ shopping p-1a2b3c4d: buy]
//     Buy this for me: Trail Runner 2 (Colour: Navy) from Example Outfitters for $129.99.
//     https://example.com/p/trail-runner-2
//     Check the price and that it is in stock, …
//
//     [Hermes HQ order o-1a2b3c4d: pay]
//     Place this order now: Example Outfitters, total $140.39. Pay exactly this total. …
//
// Everything here reads the transcript alone, so a card shows the same state after a relaunch and on another device.
// Ids are made from the call's own words (the add-on makes the same ones), so nothing depends on the tool's result.
// Parsing is lenient: the add-on checks strictly and tells the model what to fix; here a wrong value is left out and
// a product without its title, store or link is dropped, never a crash.

import CryptoKit
import Foundation

nonisolated enum ShoppingCards {
    static let productsTool = "show_products"
    static let orderTool = "order_card"
    static let tools: Set<String> = [productsTool, orderTool]
    /// Their arguments are kept whole up to this size (twelve products with photos, reasons and offers run past the
    /// 4 KB every other call keeps, `ToolArgs.maxBytes`): the cards draw them.
    static let maxArgsBytes = 256_000

    // The counts and lengths of spec §2.1 / §2.2: more is cut to this, never refused here.
    static let maxProducts = 12, maxImages = 8, maxWhy = 3, maxCaution = 2, maxOptions = 4, maxSpecs = 8, maxOffers = 5
    static let maxFollowUps = 3, maxItems = 20, maxCharges = 6

    // MARK: Models

    enum Stock: String, Hashable, Sendable { case inStock = "in", out, preorder, backorder }

    struct Option: Hashable, Sendable {
        var name: String
        var value: String
    }

    struct Spec: Hashable, Sendable {
        var label: String
        var value: String
    }

    /// The same product at another store (Where to Buy).
    struct Offer: Hashable, Sendable {
        var store: String
        var url: URL
        var price: Double?
        var was: Double?
        var stock: Stock
        var delivery: String
    }

    struct Product: Hashable, Sendable {
        var id: String
        var title: String
        var store: String
        var url: URL
        var price: Double?
        var currency: String
        /// The list price, only when above `price`.
        var was: Double?
        /// The main photo first, then the others (https only).
        var images: [URL]
        var brand: String
        var rating: Double?
        var reviews: Int?
        var badge: String
        var stock: Stock
        var delivery: String
        var why: [String]
        var caution: [String]
        var options: [Option]
        var specs: [Spec]
        var offers: [Offer]

        var image: URL? { images.first }
        /// The page's main button is Buy (Notify Me when out of stock).
        var buyable: Bool { stock != .out }
    }

    struct Products: Hashable, Sendable {
        var note: String
        var products: [Product]
        var followUps: [String]
    }

    struct Item: Hashable, Sendable {
        var title: String
        var detail: String
        var qty: Int
        var price: Double?
        var image: URL?
        var url: URL? = nil
        var options: [Option] = []
    }

    struct Charge: Hashable, Sendable {
        var label: String
        var amount: Double
    }

    struct Order: Hashable, Sendable {
        var id: String
        var store: String
        var site: URL?
        var items: [Item]
        var charges: [Charge]
        var total: Double
        var currency: String
        var shipName: String
        var shipAddress: String
        var payWith: String
        var arrives: String
        var note: String
    }

    // MARK: The add-on

    /// PUT here (under the add-on's route) says an app that draws these cards uses this computer; until then the
    /// add-on keeps both tools from its bots, so a product or an order is never left where nobody sees a card.
    static let cardsPath = "/shopping/cards"

    /// The add-on has the tools (`shoppingCards`) and hasn't heard from such an app (`shoppingCardsShown`).
    static func cardsUntold(_ status: [String: Any]?) -> Bool {
        (status?["shoppingCards"] as? NSNumber)?.boolValue == true && (status?["shoppingCardsShown"] as? NSNumber)?.boolValue != true
    }

    // MARK: The calls

    /// A shopping call's arguments as text, whole; nil for any other tool or one too big to keep.
    static func wholeArgsText(name: String, args: [String: JSONValue]) -> String? {
        guard tools.contains(name), !args.isEmpty else { return nil }
        let text = ChatJSON.stringify(.object(args))
        return text.utf8.count <= maxArgsBytes ? text : nil
    }

    private static func args(_ call: ToolCall, _ name: String) -> [String: JSONValue]? {
        guard call.name == name, call.state != .failed, let text = call.argsText else { return nil }
        return ChatJSON.parse(string: text)?.object
    }

    /// The products a `show_products` call holds; nil when it isn't one, it failed, its arguments aren't whole (a
    /// cached transcript cut them) or no product has a title, a store and a link.
    static func products(_ call: ToolCall) -> Products? {
        guard let args = args(call, productsTool) else { return nil }
        return products(args)
    }

    static func products(_ args: [String: JSONValue]) -> Products? {
        let list = (args["products"]?.array ?? []).compactMap { $0.object.flatMap(product) }
        guard !list.isEmpty else { return nil }
        let follow = strings(args["follow_ups"] ?? args["followUps"], max: maxFollowUps, length: 60)
        return Products(note: text(args["note"], 200), products: Array(list.prefix(maxProducts)), followUps: follow)
    }

    static func product(_ o: [String: JSONValue]) -> Product? {
        let title = trimmed(o["title"]), store = trimmed(o["store"]), link = trimmed(o["url"])
        guard !title.isEmpty, !store.isEmpty, let url = https(link) else { return nil }
        let price = amount(o["price"])
        var images: [URL] = []
        for value in [o["image"]] + (o["images"]?.array ?? []).map(Optional.some) {
            if let url = https(trimmed(value)), !images.contains(url) { images.append(url) }
        }
        let rating = amount(o["rating"]).map { min(5, max(0, $0)) }
        let reviews = amount(o["reviews"]).flatMap { $0 >= 0 && $0 < 1e12 ? Int($0) : nil }
        return Product(id: productId(title: title, store: store, url: link), title: cut(title, 160), store: cut(store, 60), url: url,
                       price: price, currency: currency(o["currency"]), was: above(amount(o["was"]), price),
                       images: Array(images.prefix(1 + maxImages)), brand: text(o["brand"], 60), rating: rating, reviews: reviews,
                       badge: text(o["badge"], 24), stock: stock(o["stock"]), delivery: text(o["delivery"], 80),
                       why: strings(o["why"], max: maxWhy, length: 120), caution: strings(o["caution"], max: maxCaution, length: 120),
                       options: pairs(o["options"], keys: ("name", "value"), max: maxOptions).map { Option(name: $0.0, value: $0.1) },
                       specs: pairs(o["specs"], keys: ("label", "value"), max: maxSpecs).map { Spec(label: $0.0, value: $0.1) },
                       offers: (o["offers"]?.array ?? []).compactMap { $0.object.flatMap(offer) }.prefix(maxOffers).map { $0 })
    }

    static func offer(_ o: [String: JSONValue]) -> Offer? {
        let store = trimmed(o["store"])
        guard !store.isEmpty, let url = https(trimmed(o["url"])) else { return nil }
        let price = amount(o["price"])
        return Offer(store: cut(store, 60), url: url, price: price, was: above(amount(o["was"]), price), stock: stock(o["stock"]),
                     delivery: text(o["delivery"], 80))
    }

    /// The order an `order_card` call holds; nil when it isn't one, it failed, or it lacks a store, an item or the total.
    static func order(_ call: ToolCall) -> Order? {
        guard let args = args(call, orderTool) else { return nil }
        return order(args)
    }

    static func order(_ o: [String: JSONValue]) -> Order? {
        let store = trimmed(o["store"])
        guard !store.isEmpty, let total = amount(o["total"]) else { return nil }
        let items: [Item] = (o["items"]?.array ?? []).compactMap { value in
            guard let i = value.object else { return nil }
            let title = trimmed(i["title"])
            guard !title.isEmpty else { return nil }
            let opts = pairs(i["options"], keys: ("name", "value"), max: maxOptions).map { Option(name: $0.0, value: $0.1) }
            return Item(title: title, detail: text(i["detail"], 120), qty: quantity(i["qty"]), price: amount(i["price"]),
                        image: https(trimmed(i["image"])), url: https(trimmed(i["url"])), options: opts)
        }
        guard !items.isEmpty else { return nil }
        let kept = Array(items.prefix(maxItems))
        let charges: [Charge] = (o["charges"]?.array ?? []).compactMap { value in
            guard let c = value.object, let amount = amount(c["amount"]) else { return nil }
            let label = trimmed(c["label"])
            return label.isEmpty ? nil : Charge(label: cut(label, 40), amount: amount)
        }
        let ship = o["ship_to"]?.object ?? o["shipTo"]?.object ?? [:]
        let code = currency(o["currency"])
        return Order(id: orderId(store: store, total: total, currency: code, items: kept), store: cut(store, 60),
                     site: https(trimmed(o["site"])), items: kept, charges: Array(charges.prefix(maxCharges)), total: total,
                     currency: code, shipName: text(ship["name"], 80), shipAddress: text(ship["address"], 200),
                     payWith: text(o["pay_with"] ?? o["payWith"], 60), arrives: text(o["arrives"], 60), note: text(o["note"], 160))
    }

    /// Every product shown by `show_products` across `messages` (newest last).
    static func catalogProducts(in messages: [ChatMessage]) -> [Product] {
        var out: [Product] = []
        for message in messages where message.role == .assistant {
            for case .tool(let call) in message.parts {
                if let shown = products(call) { out.append(contentsOf: shown.products) }
            }
        }
        return out
    }

    /// The product page an order line opens, with the line's own options and price. In order: the shown product
    /// with the line's link; the shown product of that name from that store (at the line's link, if it has one);
    /// a page made from the line's own link; a shown product of that name when the order names no store (or the
    /// product doesn't); the store's site.
    /// A line with its own link never opens another product's page, and a name alone never crosses to another
    /// store: "USB-C cable" from one shop is not the "USB-C cable" another shop showed earlier.
    static func product(for item: Item, in order: Order, matching history: [Product] = []) -> Product? {
        let selectedOptions = parsedOptions(for: item)
        if let url = item.url, let found = history.last(where: { $0.url == url }) {
            return applying(selectedOptions, item: item, to: found)
        }
        func norm(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let normTitle = norm(item.title), normStore = norm(order.store)
        if !normTitle.isEmpty {
            if let found = history.last(where: { norm($0.title) == normTitle && norm($0.store) == normStore }) {
                // The same product from the same store: its pictures and reasons, at the line's own link if it has
                // one (a link to the chosen colour, say).
                var product = applying(selectedOptions, item: item, to: found)
                if let url = item.url { product.url = url }
                return product
            }
            if item.url == nil, let found = history.last(where: { norm($0.title) == normTitle && (normStore.isEmpty || norm($0.store).isEmpty) }) {
                return applying(selectedOptions, item: item, to: found)
            }
        }
        guard let url = item.url ?? order.site else { return nil }
        return Product(
            id: productId(title: item.title, store: order.store, url: url.absoluteString),
            title: cut(item.title, 160),
            store: order.store,
            url: url,
            price: item.price,
            currency: order.currency,
            was: nil,
            images: item.image.map { [$0] } ?? [],
            brand: "",
            rating: nil,
            reviews: nil,
            badge: "",
            stock: .inStock,
            delivery: order.arrives,
            why: [],
            caution: [],
            options: selectedOptions,
            specs: [],
            offers: []
        )
    }

    /// Indices of items in `order` that can open a product page.
    static func openableItemIndices(in order: Order, matching history: [Product]) -> Set<Int> {
        var out: Set<Int> = []
        for (i, item) in order.items.enumerated() where product(for: item, in: order, matching: history) != nil {
            out.insert(i)
        }
        return out
    }

    private static func applying(_ options: [Option], item: Item, to base: Product) -> Product {
        var copy = base
        if !options.isEmpty { copy.options = options }
        if let price = item.price { copy.price = price }
        if let img = item.image, !copy.images.contains(img) { copy.images.insert(img, at: 0) }
        return copy
    }

    /// Parses selected options from `item.options` or falls back to splitting `item.detail` ("Navy, M" / "Color: Navy, Size: M").
    private static func parsedOptions(for item: Item) -> [Option] {
        if !item.options.isEmpty { return item.options }
        guard !item.detail.isEmpty else { return [] }
        let parts = item.detail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.prefix(maxOptions).enumerated().map { idx, part in
            if let colon = part.firstIndex(of: ":") {
                let k = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty && !v.isEmpty { return Option(name: k, value: v) }
            }
            return Option(name: idx == 0 ? "Option" : "Detail", value: part)
        }
    }

    // MARK: Ids (both sides compute them)

    /// "p-" and the first 8 hex digits of SHA-256 over `title\nstore\nurl`, each trimmed.
    static func productId(title: String, store: String, url: String) -> String {
        "p-" + hex8([title, store, url].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n"))
    }

    /// "o-" and the first 8 hex digits of SHA-256 over `store\ntotal\ncurrency\n` and each item's `qty x title`
    /// joined by newlines (the total with two decimals: "140.39").
    static func orderId(store: String, total: Double, currency: String, items: [Item]) -> String {
        let head = [store.trimmingCharacters(in: .whitespacesAndNewlines), String(format: "%.2f", total),
                    currency.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n")
        let lines = items.map { "\($0.qty) x \($0.title.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return "o-" + hex8(head + "\n" + lines.joined(separator: "\n"))
    }

    private static func hex8(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading values

    private static func trimmed(_ value: JSONValue?) -> String {
        (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cut(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A one-line string of at most `max` characters (line breaks become spaces).
    private static func text(_ value: JSONValue?, _ max: Int) -> String {
        cut(trimmed(value).split(whereSeparator: \.isNewline).joined(separator: " "), max)
    }

    private static func strings(_ value: JSONValue?, max: Int, length: Int) -> [String] {
        let items = value?.array ?? (value?.string.map { [JSONValue.string($0)] } ?? [])
        return Array(items.map { text($0, length) }.filter { !$0.isEmpty }.prefix(max))
    }

    private static func pairs(_ value: JSONValue?, keys: (String, String), max: Int) -> [(String, String)] {
        let found: [(String, String)] = (value?.array ?? []).compactMap { item in
            guard let o = item.object else { return nil }
            let a = text(o[keys.0], 40), b = text(o[keys.1], 80)
            return a.isEmpty || b.isEmpty ? nil : (a, b)
        }
        return Array(found.prefix(max))
    }

    /// A number, or a plain numeric string ("129.99"); never NaN, infinite or negative-zero noise.
    private static func amount(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        let n: Double?
        switch value {
        case .number(let d): n = d
        case .string(let s): n = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
        default: n = nil
        }
        guard let n, n.isFinite, abs(n) < 1e12 else { return nil }
        return n
    }

    private static func above(_ was: Double?, _ price: Double?) -> Double? {
        guard let was, let price, was > price else { return nil }
        return was
    }

    private static func quantity(_ value: JSONValue?) -> Int {
        guard let n = amount(value), n >= 1 else { return 1 }
        return Int(min(n, 999))
    }

    private static func currency(_ value: JSONValue?) -> String {
        let code = trimmed(value)
        return code.count == 3 && code.allSatisfy(\.isLetter) ? code : "USD"
    }

    private static func stock(_ value: JSONValue?) -> Stock {
        Stock(rawValue: trimmed(value).lowercased()) ?? .inStock
    }

    private static func https(_ text: String) -> URL? {
        guard text.lowercased().hasPrefix("https://"), let url = URL(string: text), url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Words

    /// The locale the bot reads prices in (the messages); the cards use the person's own.
    static let messageLocale = Locale(identifier: "en_US")

    /// "$129.99" (in `locale`'s way of writing `currency`).
    static func price(_ amount: Double, currency: String, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }

    /// The product's price, or nil when it has none.
    static func priceText(_ p: Product, locale: Locale = .current) -> String? {
        p.price.map { price($0, currency: p.currency, locale: locale) }
    }

    /// The struck list price, only when it is above the price.
    static func wasText(_ p: Product, locale: Locale = .current) -> String? {
        p.was.map { price($0, currency: p.currency, locale: locale) }
    }

    /// "4.6 (1,234)", "4.6", or nil without a rating.
    static func ratingText(_ rating: Double?, reviews: Int?, locale: Locale = .current) -> String? {
        guard let rating else { return nil }
        let r = NumberFormatter()
        r.locale = locale
        r.minimumFractionDigits = 1
        r.maximumFractionDigits = 1
        let stars = r.string(from: NSNumber(value: rating)) ?? String(format: "%.1f", rating)
        guard let reviews, reviews > 0 else { return stars }
        let n = NumberFormatter()
        n.locale = locale
        n.numberStyle = .decimal
        return "\(stars) (\(n.string(from: NSNumber(value: reviews)) ?? String(reviews)))"
    }

    static func stockText(_ stock: Stock) -> String? {
        switch stock {
        case .inStock: nil
        case .out: "Out of stock"
        case .preorder: "Pre-order"
        case .backorder: "Back-ordered"
        }
    }

    /// "Colour: Navy, Size: M", empty when the bot named none.
    static func optionsText(_ p: Product) -> String {
        p.options.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
    }

    static func totalText(_ o: Order, locale: Locale = .current) -> String { price(o.total, currency: o.currency, locale: locale) }

    // MARK: The answers (spec §2.3)

    enum Ask: String, Hashable, Sendable, CaseIterable {
        case buy
        case watchStock = "watch stock"
        case watchPrice = "watch price"
    }

    enum OrderAnswer: String, Hashable, Sendable { case pay, cancel }

    enum OrderState: Hashable, Sendable { case waiting, approved, cancelled, replaced }

    private static let watchJob = "Set up a scheduled job that checks every 6 hours (use your price watch job if you have one)"

    private static func named(_ p: Product) -> String {
        let options = optionsText(p)
        return options.isEmpty ? p.title : "\(p.title) (\(options))"
    }

    /// What Buy sends.
    static func buyMessage(_ p: Product) -> String {
        let cost = priceText(p, locale: messageLocale).map { " for \($0)" } ?? ""
        return ["[Hermes HQ shopping \(p.id): buy]",
                "Buy this for me: \(named(p)) from \(p.store)\(cost).",
                p.url.absoluteString,
                "Check the price and that it is in stock, take it to the last step of checkout, then show me the order with "
                    + "order_card and wait for my answer before you pay."].joined(separator: "\n")
    }

    /// What Notify Me (out of stock) sends.
    static func watchStockMessage(_ p: Product) -> String {
        ["[Hermes HQ shopping \(p.id): watch stock]",
         "Tell me when this is back in stock: \(named(p)) at \(p.store).",
         p.url.absoluteString,
         watchJob + " and tells me only when it is available."].joined(separator: "\n")
    }

    /// What Notify Me of a Price Drop sends; nil for a product without a price.
    static func watchPriceMessage(_ p: Product) -> String? {
        guard let cost = priceText(p, locale: messageLocale) else { return nil }
        return ["[Hermes HQ shopping \(p.id): watch price]",
                "Tell me when the price of this drops below \(cost): \(p.title) at \(p.store).",
                p.url.absoluteString,
                watchJob + " and tells me only when it drops."].joined(separator: "\n")
    }

    static func message(_ ask: Ask, _ p: Product) -> String? {
        switch ask {
        case .buy: buyMessage(p)
        case .watchStock: watchStockMessage(p)
        case .watchPrice: watchPriceMessage(p)
        }
    }

    /// What Pay sends.
    static func payMessage(_ o: Order) -> String {
        "[Hermes HQ order \(o.id): pay]\nPlace this order now: \(o.store), total \(totalText(o, locale: messageLocale)). "
            + "Pay exactly this total. If the total on the page is different now, stop and show me a new order card."
    }

    /// What Cancel sends.
    static func cancelMessage(_ o: Order) -> String {
        "[Hermes HQ order \(o.id): cancel]\nDon't place this order. Nothing should be charged."
    }

    /// How every answer starts.
    static let productLead = "[Hermes HQ shopping ", orderLead = "[Hermes HQ order "
    private static let productMark = TRx(#"^\s*\[Hermes HQ shopping (p-[0-9a-f]{8}): (buy|watch stock|watch price)\]"#)
    private static let orderMark = TRx(#"^\s*\[Hermes HQ order (o-[0-9a-f]{8}): (pay|cancel)\]"#)

    /// The product a message of yours asks about, and what it asks.
    static func productAnswer(in text: String) -> (id: String, ask: Ask)? {
        guard text.drop(while: \.isWhitespace).hasPrefix(productLead), let g = productMark.groups(text), let id = g[1],
              let ask = g[2].flatMap(Ask.init(rawValue:)) else { return nil }
        return (id, ask)
    }

    /// The order a message of yours answers, and how.
    static func orderAnswer(in text: String) -> (id: String, answer: OrderAnswer)? {
        guard text.drop(while: \.isWhitespace).hasPrefix(orderLead), let g = orderMark.groups(text), let id = g[1],
              let answer = g[2].flatMap(OrderAnswer.init(rawValue:)) else { return nil }
        return (id, answer)
    }

    /// Your bubble's words for an answer (the card above shows the rest): "Buy: Trail Runner 2", "Pay $140.39".
    static func bubbleWords(_ text: String) -> String? {
        if let found = orderAnswer(in: text) {
            guard found.answer == .pay else { return "Cancel order" }
            let line = secondLine(text)
            if let at = line.range(of: ", total ", options: .backwards) {
                let rest = line[at.upperBound...]
                let total = rest.range(of: ". Pay exactly").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
                if !total.isEmpty { return "Pay \(total)" }
            }
            return "Pay"
        }
        guard let found = productAnswer(in: text) else { return nil }
        let line = secondLine(text)
        switch found.ask {
        case .buy: return between(line, "Buy this for me: ", " from ").map { "Buy: \($0)" } ?? "Buy"
        case .watchStock: return between(line, "Tell me when this is back in stock: ", " at ").map { "Notify me: \($0)" } ?? "Notify me"
        case .watchPrice:
            guard let colon = line.range(of: ": ") else { return "Notify me of a price drop" }
            return between(String(line[colon.upperBound...]), "", " at ").map { "Notify me of a price drop: \($0)" } ?? "Notify me of a price drop"
        }
    }

    private static func secondLine(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 1 ? String(lines[1]) : ""
    }

    /// What lies after `lead` and before the last `end` of `line` (the title, which may hold the word itself).
    private static func between(_ line: String, _ lead: String, _ end: String) -> String? {
        guard line.hasPrefix(lead), let stop = line.range(of: end, options: .backwards), stop.lowerBound >= line.index(line.startIndex, offsetBy: lead.count) else { return nil }
        let words = line[line.index(line.startIndex, offsetBy: lead.count)..<stop.lowerBound].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }

    /// Everything the chat's own messages say about its cards.
    struct Answers: Hashable, Sendable {
        /// Product id → what you asked for it.
        var asked: [String: Set<Ask>] = [:]
        /// Order id → your answer (the newest wins).
        var orders: [String: OrderAnswer] = [:]
        /// Order call id → how its card stands.
        var orderStates: [String: OrderState] = [:]
    }

    /// Every answer of the chat's messages; `queued`: answers still waiting behind a running reply (they count too:
    /// they are newer). An order card with no answer is waiting, unless a newer order card follows it (replaced).
    static func answers(_ messages: [ChatMessage], queued: [String] = []) -> Answers {
        var out = Answers()
        var orderCalls: [(callId: String, orderId: String)] = []
        func read(_ text: String) {
            if let found = productAnswer(in: text) { out.asked[found.id, default: []].insert(found.ask) }
            if let found = orderAnswer(in: text) { out.orders[found.id] = found.answer }
        }
        for message in messages {
            for part in message.parts {
                switch part {
                case .text(let text) where message.role == .user: read(text)
                case .tool(let call) where message.role == .assistant && call.name == orderTool:
                    if let order = order(call) { orderCalls.append((call.id, order.id)) }
                default: break
                }
            }
        }
        queued.forEach(read)
        for (index, card) in orderCalls.enumerated() {
            switch out.orders[card.orderId] {
            case .pay: out.orderStates[card.callId] = .approved
            case .cancel: out.orderStates[card.callId] = .cancelled
            case nil: out.orderStates[card.callId] = index < orderCalls.count - 1 ? .replaced : .waiting
            }
        }
        return out
    }

    /// The line a settled order card shows.
    static func status(_ state: OrderState, _ o: Order, locale: Locale = .current) -> String? {
        switch state {
        case .waiting: nil
        case .approved: "You approved \(totalText(o, locale: locale))"
        case .cancelled: "Cancelled. Nothing was charged."
        case .replaced: "A newer order replaced this one"
        }
    }

    /// The quiet line on a product's page once you asked for it.
    static func askedText(_ asks: Set<Ask>) -> String? {
        if asks.contains(.buy) { return "Asked to buy" }
        if asks.contains(.watchStock) || asks.contains(.watchPrice) { return "Watching" }
        return nil
    }
}
