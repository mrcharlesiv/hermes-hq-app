import UIKit

// [shopping] A bot's product cards in the chat (docs/spec/3x-shopping.md §1.1, §3). By count: one product is one
// wide card with its Buy button (it is the whole answer); two sit side by side; three to eight are a row that
// scrolls sideways; nine to twelve are a list of compact rows, the first five and then one short "7 more ›" line.
// Dense: the name on one line, then the price line with the rating at its end, then the store line; a list row is the
// name (its stock or badge at the end), then price, old price and store (the rating at the end). Nothing on a card
// ends in "…" while the words fit another way: the rating moves to the store line or leaves the card first. A card
// opens the product's page (ProductPageSheet).
// `ProductCardsLayout` measures (pure, any thread); `ProductCardsView` draws what it measured.

// MARK: - Layout

nonisolated struct ProductFonts: @unchecked Sendable {
    var name, price, was, meta, metaStrong, badge, button, note, chip: UIFont

    init(_ category: UIContentSizeCategory) {
        name = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 22)
        price = PromptFonts.font(.subheadline, category, weight: .semibold, cap: 22)
        was = PromptFonts.font(.footnote, category, cap: 20)
        meta = PromptFonts.font(.footnote, category, cap: 20)
        metaStrong = PromptFonts.font(.footnote, category, weight: .semibold, cap: 20)
        badge = PromptFonts.font(.caption2, category, weight: .semibold, cap: 16)
        button = PromptFonts.button(category)
        note = PromptFonts.font(.subheadline, category)
        chip = PromptFonts.font(.footnote, category, weight: .medium, cap: 20)
    }

    func line(_ font: UIFont) -> CGFloat { ceil(font.lineHeight) }
}

nonisolated struct ProductCardsGeometry: @unchecked Sendable {
    enum Mode: Sendable { case single, pair, row, list }
    var mode: Mode
    var fonts: ProductFonts
    /// The bot's line over the cards (two lines at most), in the row's coordinates: drawn by the prompt cell with the
    /// text layout it was measured with, so its wrapping and its height always agree.
    var note: (text: String, placed: PromptPlacedText)?
    /// Each shown product's frame: in the row (single, pair), in the strip's content (row), or in the list card (list).
    var cards: [CGRect]
    /// The sideways strip (row): its frame in the row, its content's width, and carousel paging metrics.
    var strip: CGRect?
    var stripContent: CGFloat = 0
    var carousel: ChatCarouselMetrics? = nil
    /// The soft card the list's rows sit in (list), in the row.
    var listCard: CGRect?
    /// The list's last line, "7 more ›" / "Show Less" (list), in the list card: as short as its words.
    var seeAll: (title: String, frame: CGRect)?
    /// The follow-up chips, in the row.
    var followUps: [(text: String, frame: CGRect)]
    /// The photo's height in a card (pair, row), its side (single), or the thumbnail's side (list).
    var photo: CGFloat
    var buttonHeight: CGFloat
    /// The one product's card: its store and its button share the bottom line; the button's width.
    var singleBeside = false
    var singleButton: CGFloat = 0
}

/// Where a card's pieces sit, in the card's own coordinates, and the words they hold. A card never shows a "…" where
/// the words fit another way: the rating moves to the store line, or leaves the card (the page has it), first.
nonisolated struct ProductCardParts {
    var photo: CGRect
    var name: CGRect
    /// The price and the struck old price (single, pair, row); a list row's whole second line.
    var price: CGRect
    var priceText = NSAttributedString()
    /// The store (single, pair, row); nothing in a list row.
    var meta: CGRect
    var metaText = NSAttributedString()
    /// "★ 4.4" at the trailing end of the price line or the store line, when it fits.
    var rating: CGRect?
    var ratingText = NSAttributedString()
    /// A list row's badge or stock, at the trailing end of its name line.
    var accessory: CGRect?
    var accessoryText = NSAttributedString()
    /// The one product's Buy / Notify Me (single).
    var button: CGRect?
}

nonisolated enum ProductCardsLayout {
    static let side: CGFloat = 16, gapBetween: CGFloat = 8, pad: CGFloat = 10
    /// A long list shows this many rows until "7 more".
    static let listFirst = 5
    /// The room between a line's words and what sits at its trailing end.
    static let trailingGap: CGFloat = 6

    static func mode(_ count: Int) -> ProductCardsGeometry.Mode {
        switch count {
        case ...1: .single
        case 2: .pair
        case 3...8: .row
        default: .list
        }
    }

    static func make(_ card: ProductsCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let g = geometry(card, gap: gap, width: width, category: category)
        let bottom = max(g.followUps.map(\.frame.maxY).max() ?? 0,
                         g.strip?.maxY ?? 0, g.listCard?.maxY ?? 0, g.mode == .single || g.mode == .pair ? (g.cards.map(\.maxY).max() ?? 0) : 0)
        let spoken = ([card.products.note] + card.products.products.map { spokenName($0) }).filter { !$0.isEmpty }.joined(separator: ". ")
        let layout = PromptRowLayout(cardFrame: nil, texts: g.note.map { [$0.placed] } ?? [], approval: nil, shopping: .products(g),
                                     accessibility: spoken)
        return RowLayout(height: ceil(bottom + 6), content: .prompt(layout))
    }

    /// The list's last line: what is still folded away ("7 more ›", the grouped lines' wording), or Show Less.
    static func seeAllTitle(count: Int, expanded: Bool) -> String {
        expanded ? "Show Less" : "\(count - listFirst) more ›"
    }

    static func geometry(_ card: ProductsCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory,
                         wholeTiles: Bool = DeviceWord.isMac) -> ProductCardsGeometry {
        let fonts = ProductFonts(category)
        let inner = PromptLayout.cardWidth(for: width)
        let mode = mode(card.count)
        let buttonH = max(36, ceil(fonts.button.lineHeight) + 14)
        var y = gap + 6
        var note: (String, PromptPlacedText)?
        if !card.products.note.isEmpty {
            let (text, _) = PromptLayout.clamped(PromptLayout.text(card.products.note, fonts.note, ChatPalette.label2), width: inner, maxLines: 2)
            note = (card.products.note, PromptPlacedText(text: text, frame: CGRect(x: side, y: y, width: inner, height: text.size.height)))
            y += text.size.height + 8
        }
        let textH = fonts.line(fonts.name) + 2 + fonts.line(fonts.price) + 2 + fonts.line(fonts.meta)
        var g = ProductCardsGeometry(mode: mode, fonts: fonts, note: note, cards: [], followUps: [], photo: 0, buttonHeight: buttonH)
        switch mode {
        case .single:
            // The photo is as tall as the words and the button beside it, never more: name, price, then the store
            // with Buy at its end (or the store, then Buy under it, when the two don't share a line).
            let top = fonts.line(fonts.name) + 2 + fonts.line(fonts.price)
            let beside = max(76, top + 6 + buttonH)
            let w = inner - 2 * pad - beside - 12
            if let p = card.products.products.first {
                let shown = buttonTitle(p, asks: card.asks(p))
                g.singleButton = singleButtonWidth(fonts, title: shown.title, done: shown.done, width: w)
            }
            if let p = card.products.products.first, measure(storeLine(p, fonts)) <= w - g.singleButton - trailingGap {
                g.singleBeside = true
                g.photo = beside
            } else {
                g.photo = max(76, top + 2 + fonts.line(fonts.meta) + 8 + buttonH)
            }
            g.cards = [CGRect(x: side, y: y, width: inner, height: g.photo + 2 * pad)]
            y = g.cards[0].maxY
        case .pair:
            let w = floor((inner - gapBetween) / 2)
            g.photo = min(200, round(w * 0.62))   // a landscape photo: the pair stays short even on wide Mac panes
            let h = g.photo + pad + textH + pad
            g.cards = [CGRect(x: side, y: y, width: w, height: h), CGRect(x: side + inner - w, y: y, width: w, height: h)]
            y += h
        case .row:
            // On narrow phones: wide enough for "$64.99  $79.99  ★ 4.4" on one line, narrow enough that the third card
            // peeks in. On wide panes (Mac / wide iPad): fit exact whole cards within the card rail with zero cutoff.
            let phoneTile = max(164, ceil(fonts.name.pointSize * 10.9))
            let carousel = ChatCarouselMetrics.compute(
                count: card.count,
                rowWidth: width,
                cardWidth: inner,
                side: side,
                spacing: gapBetween,
                phoneTileWidth: phoneTile,
                minWideTile: phoneTile,
                maxWideTile: max(240, phoneTile + 40),
                singleWideCap: inner,
                wholeTiles: wholeTiles
            )
            let w = carousel.tileWidth
            g.photo = round(w * 0.66)
            let h = g.photo + pad + textH + pad
            g.cards = (0..<card.count).map { CGRect(x: carousel.contentInset + CGFloat($0) * carousel.stride, y: 0, width: w, height: h) }
            g.stripContent = carousel.contentWidth
            g.strip = CGRect(x: carousel.stripX, y: y, width: carousel.stripWidth, height: h)
            g.carousel = carousel
            y += h
        case .list:
            g.photo = max(44, ceil(fonts.line(fonts.name) + fonts.line(fonts.meta) + 4))
            let rowH = g.photo + 2 * 8
            let shown = card.expanded ? card.count : min(card.count, listFirst)
            g.cards = (0..<shown).map { CGRect(x: 0, y: CGFloat($0) * rowH, width: inner, height: rowH) }
            var h = CGFloat(shown) * rowH
            if card.count > listFirst {
                // Not a footer row: one short line under the last row, as tall as its words and a little air.
                let lineH = fonts.line(fonts.metaStrong) + 14
                g.seeAll = (seeAllTitle(count: card.count, expanded: card.expanded), CGRect(x: 0, y: h, width: inner, height: lineH))
                h += lineH
            }
            g.listCard = CGRect(x: side, y: y, width: inner, height: h)
            y += h
        }
        // Follow-ups: chips in lines under the cards.
        if !card.products.followUps.isEmpty {
            y += 8
            let chipH = max(32, ceil(fonts.chip.lineHeight) + 12)
            var x = side
            for text in card.products.followUps {
                let w = min(inner, ceil((text as NSString).size(withAttributes: [.font: fonts.chip]).width) + 28)
                if x > side, x + w > side + inner { x = side; y += chipH + 6 }
                g.followUps.append((text, CGRect(x: x, y: y, width: w, height: chipH)))
                x += w + 6
            }
            y += chipH
        }
        return g
    }

    /// The one product's button: a capsule as wide as its words (at least 88 pt), or once asked its plain words,
    /// ending where the card's words end.
    static func singleButtonWidth(_ f: ProductFonts, title: String, done: Bool, width: CGFloat) -> CGFloat {
        let words = ceil((title as NSString).size(withAttributes: [.font: f.button]).width)
        return min(width, done ? words + ceil(f.button.lineHeight) + 4 + 8 : max(88, words + 32))
    }

    // MARK: Parts

    /// A card's pieces at `size` (single, pair, row) or a list row's, with `p`'s words fitted to them.
    static func parts(_ g: ProductCardsGeometry, size: CGSize, product p: ShoppingCards.Product? = nil) -> ProductCardParts {
        let f = g.fonts
        let nameH = f.line(f.name), priceH = f.line(f.price), metaH = f.line(f.meta)
        switch g.mode {
        case .single:
            let photo = CGRect(x: pad, y: pad, width: g.photo, height: g.photo)
            let x = photo.maxX + 12, w = size.width - x - pad
            let name = CGRect(x: x, y: pad, width: w, height: nameH)
            let price = CGRect(x: x, y: name.maxY + 2, width: w, height: priceH)
            let buttonW = g.singleButton > 0 ? g.singleButton : min(w, 88)
            let button = CGRect(x: x + w - buttonW, y: size.height - pad - g.buttonHeight, width: buttonW, height: g.buttonHeight)
            let meta = g.singleBeside ? CGRect(x: x, y: button.midY - metaH / 2, width: w - buttonW - trailingGap, height: metaH)
                : CGRect(x: x, y: price.maxY + 2, width: w, height: metaH)
            var parts = ProductCardParts(photo: photo, name: name, price: price, meta: meta, button: button)
            if let p { fit(&parts, p, f) }
            return parts
        case .pair, .row:
            let photo = CGRect(x: 0, y: 0, width: size.width, height: g.photo)
            let w = size.width - 2 * pad
            let name = CGRect(x: pad, y: photo.maxY + pad, width: w, height: nameH)
            let price = CGRect(x: pad, y: name.maxY + 2, width: w, height: priceH)
            let meta = CGRect(x: pad, y: price.maxY + 2, width: w, height: metaH)
            var parts = ProductCardParts(photo: photo, name: name, price: price, meta: meta, button: nil)
            if let p { fit(&parts, p, f) }
            return parts
        case .list:
            let photo = CGRect(x: 12, y: 8, width: g.photo, height: g.photo)
            let x = photo.maxX + 10, w = size.width - x - 12
            let top = (size.height - nameH - 2 - metaH) / 2
            var name = CGRect(x: x, y: top, width: w, height: nameH)
            var line = CGRect(x: x, y: name.maxY + 2, width: w, height: metaH)
            var parts = ProductCardParts(photo: photo, name: name, price: line, meta: .zero)
            guard let p else { return parts }
            // The name line: the name, then the stock (or the bot's badge) at its end.
            if let accessory = listAccessory(p, f) {
                let aw = measure(accessory)
                parts.accessoryText = accessory
                parts.accessory = CGRect(x: x + w - aw, y: name.minY + (nameH - metaH) / 2, width: aw, height: metaH)
                name.size.width = max(40, w - aw - trailingGap)
            }
            // The second line: price, old price, store, and the rating at its end when all of that fits.
            parts.priceText = listLine(p, f)
            if let rating = ratingLine(p, f) {
                let rw = measure(rating)
                if measure(parts.priceText) + trailingGap + rw <= w {
                    parts.ratingText = rating
                    parts.rating = CGRect(x: x + w - rw, y: line.minY, width: rw, height: metaH)
                    line.size.width = w - rw - trailingGap
                }
            }
            parts.name = name
            parts.price = line
            return parts
        }
    }

    /// The card's words: the price line, the store line, and the rating at the end of whichever has room.
    private static func fit(_ parts: inout ProductCardParts, _ p: ShoppingCards.Product, _ f: ProductFonts) {
        var price = priceLine(p, f)
        if measure(price) > parts.price.width { price = priceLine(p, f, was: false) }   // the old price is on the page
        parts.priceText = price
        parts.metaText = storeLine(p, f)
        guard let rating = ratingLine(p, f) else { return }
        let rw = measure(rating)
        parts.ratingText = rating
        if measure(price) + trailingGap + rw <= parts.price.width {
            parts.rating = CGRect(x: parts.price.maxX - rw, y: parts.price.minY + (parts.price.height - parts.meta.height) / 2,
                                  width: rw, height: parts.meta.height)
            parts.price.size.width -= rw + trailingGap
        } else if measure(parts.metaText) + trailingGap + rw <= parts.meta.width {
            parts.rating = CGRect(x: parts.meta.maxX - rw, y: parts.meta.minY, width: rw, height: parts.meta.height)
            parts.meta.size.width -= rw + trailingGap
        }
    }

    static func measure(_ text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200), options: [.usesLineFragmentOrigin],
                               context: nil).width)
    }

    // MARK: Words

    /// The struck old price after a price: a gap that is not struck (kerning, not a space, so the line can't run on).
    private static func appendWas(_ was: String, to out: NSMutableAttributedString, font: UIFont, gap: CGFloat) {
        if out.length > 0 { out.addAttribute(.kern, value: gap, range: NSRange(location: out.length - 1, length: 1)) }
        out.append(NSAttributedString(string: was, attributes: [
            .font: font, .foregroundColor: ChatPalette.label3, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: ChatPalette.label3]))
    }

    /// "$129.99  ~~$159.99~~"; the stock alone when there's no price.
    static func priceLine(_ p: ShoppingCards.Product, _ f: ProductFonts, was showWas: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let price = ShoppingCards.priceText(p) {
            out.append(NSAttributedString(string: price, attributes: [.font: f.price, .foregroundColor: ChatPalette.label]))
        }
        if showWas, let was = ShoppingCards.wasText(p) { appendWas(was, to: out, font: f.was, gap: 5) }
        if out.length == 0, let stock = ShoppingCards.stockText(p.stock) {
            out.append(NSAttributedString(string: stock, attributes: [.font: f.price, .foregroundColor: ChatPalette.label2]))
        }
        return out
    }

    /// The store, alone on its line.
    static func storeLine(_ p: ShoppingCards.Product, _ f: ProductFonts) -> NSAttributedString {
        NSAttributedString(string: p.store, attributes: [.font: f.meta, .foregroundColor: ChatPalette.label2])
    }

    /// "★ 4.6": the count of reviews is on the product's page.
    static func ratingLine(_ p: ShoppingCards.Product, _ f: ProductFonts) -> NSAttributedString? {
        guard let rating = ShoppingCards.ratingText(p.rating, reviews: nil) else { return nil }
        return NSAttributedString(string: "★ " + rating, attributes: [.font: f.meta, .foregroundColor: ChatPalette.label2])
    }

    /// The pill over a card's photo: its stock when it can't be bought now, else the bot's badge.
    static func photoBadge(_ p: ShoppingCards.Product) -> (text: String, quiet: Bool)? {
        if let stock = ShoppingCards.stockText(p.stock) { return (stock, true) }
        return p.badge.isEmpty ? nil : (p.badge, false)
    }

    /// A list row's name line ends with its stock, or else the bot's badge.
    static func listAccessory(_ p: ShoppingCards.Product, _ f: ProductFonts) -> NSAttributedString? {
        if let stock = ShoppingCards.stockText(p.stock) {
            return NSAttributedString(string: stock, attributes: [.font: f.meta, .foregroundColor: ChatPalette.label2])
        }
        guard !p.badge.isEmpty else { return nil }
        return NSAttributedString(string: p.badge, attributes: [.font: f.metaStrong, .foregroundColor: ChatPalette.tintText])
    }

    /// A list row's second line: "$13.75  ~~$24.00~~ · Demo Goods" (the rating sits at its end when it fits).
    static func listLine(_ p: ShoppingCards.Product, _ f: ProductFonts) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let price = ShoppingCards.priceText(p) {
            out.append(NSAttributedString(string: price, attributes: [.font: f.metaStrong, .foregroundColor: ChatPalette.label]))
        }
        let struck = ShoppingCards.wasText(p) != nil
        if let was = ShoppingCards.wasText(p) { appendWas(was, to: out, font: f.meta, gap: 5) }
        if out.length > 0 {
            // The strike runs on over whitespace (and kerning) up to the next glyph, so after the old price the gap is
            // an unseen glyph, not a space: the strike stops at the price's last digit.
            let gap: [NSAttributedString.Key: Any] = struck ? [.font: f.meta, .foregroundColor: UIColor.clear] : [.font: f.meta]
            out.append(NSAttributedString(string: struck ? "·" : " ", attributes: gap))
            out.append(NSAttributedString(string: "· ", attributes: [.font: f.meta, .foregroundColor: ChatPalette.label2]))
        }
        out.append(NSAttributedString(string: p.store, attributes: [.font: f.meta, .foregroundColor: ChatPalette.label2]))
        return out
    }

    /// What VoiceOver reads for a card.
    static func spokenName(_ p: ShoppingCards.Product) -> String {
        var parts = [p.title]
        if let price = ShoppingCards.priceText(p) { parts.append(price) }
        if let was = ShoppingCards.wasText(p) { parts.append("was \(was)") }
        if let stock = ShoppingCards.stockText(p.stock) { parts.append(stock) }
        parts.append(p.store)
        if let rating = p.rating { parts.append(String(format: "rated %.1f of 5", rating)) }
        if !p.badge.isEmpty { parts.append(p.badge) }
        return parts.joined(separator: ", ")
    }

    /// The single card's button: Buy, or Notify Me when out of stock; once asked, the page's own quiet words.
    static func buttonTitle(_ p: ShoppingCards.Product, asks: Set<ShoppingCards.Ask>) -> (title: String, ask: ShoppingCards.Ask, done: Bool) {
        if p.buyable { return asks.contains(.buy) ? ("Asked to buy", .buy, true) : ("Buy", .buy, false) }
        return asks.contains(.watchStock) ? ("Watching", .watchStock, true) : ("Notify Me", .watchStock, false)
    }
}

// MARK: - View

/// The cards of one `show_products` call (the cell places it over the whole row).
final class ProductCardsView: UIView, UIScrollViewDelegate {
    var onOpen: ((Int) -> Void)?
    var onAsk: ((Int, ShoppingCards.Ask) -> Void)?
    var onFollowUp: ((String) -> Void)?
    var onToggle: (() -> Void)?

    /// VoiceOver's stop for the bot's line (the cell draws its words).
    private lazy var note = UIAccessibilityElement(accessibilityContainer: self)
    private let strip = UIScrollView()
    private var arrows: ChatCarouselArrows?
    private var carouselMetrics: ChatCarouselMetrics?
    private let listCard = UIView()
    private let seeAll = UIButton(type: .system)
    private let seeAllRule = UIView()
    private var cards: [ProductCardView] = []
    private var chips: [UIButton] = []
    private var lastShownCount = 0
    private var lastHasNote = false
    private var lastHasSeeAll = false
    private var lastFollowUpCount = 0
    private var rowId = ""
    private var isConfiguring = false
    /// Where each strip was scrolled to, by row: a cell drawn again keeps its place.
    private static var offsets: [String: CGFloat] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        strip.delegate = self
        strip.clipsToBounds = true
        #if targetEnvironment(macCatalyst)
        strip.delaysContentTouches = false
        #endif
        addSubview(strip)
        arrows = ChatCarouselArrows(in: self, identifier: "shopping.products", itemNoun: "products") { [weak self] forward in
            self?.stepStrip(forward: forward)
        }
        listCard.layer.cornerRadius = ChatMetrics.insetCardRadius
        listCard.layer.cornerCurve = .continuous
        listCard.clipsToBounds = true
        addSubview(listCard)
        seeAll.accessibilityIdentifier = "shopping.seeAll"
        seeAll.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onToggle?()
        }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(seeAll)
        #endif
        listCard.addSubview(seeAll)
        seeAllRule.isUserInteractionEnabled = false
        listCard.addSubview(seeAllRule)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ProductCardsView, _) in
            view.styleListCard()
            view.arrows?.restyle()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func stepStrip(forward: Bool) {
        guard let metrics = carouselMetrics else { return }
        let targetX = metrics.steppedOffset(from: strip.contentOffset.x, forward: forward)
        strip.setContentOffset(CGPoint(x: targetX, y: 0), animated: !HQMotion.reduced)
        if HQMotion.reduced { arrows?.update() }
    }

    private func styleListCard() {
        listCard.layer.cornerRadius = ChatMetrics.insetCardRadius
        listCard.backgroundColor = ChatPalette.promptCard
        let edge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
        listCard.layer.borderColor = edge.cgColor
        listCard.layer.borderWidth = edge.cgColor.alpha > 0 ? max(HQShape.pixel(traitCollection.displayScale), 1) : 0
    }

    func configure(_ row: ProductsCardRow, _ g: ProductCardsGeometry) {
        isConfiguring = true
        defer { isConfiguring = false }
        let sameRow = rowId == row.rowId
        rowId = row.rowId
        accessibilityIdentifier = "shopping.products"
        if let n = g.note {
            note.accessibilityLabel = n.text
            note.accessibilityFrameInContainerSpace = n.placed.frame
        }
        let products = row.products.products
        let shown = g.cards.count
        while cards.count < shown {
            let card = ProductCardView()
            let index = cards.count
            card.addAction(UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.onOpen?(index)
            }, for: .touchUpInside)   // a plain UIControl never sends .primaryActionTriggered (only UIButton does)
            card.onAsk = { [weak self] ask in self?.onAsk?(index, ask) }
            cards.append(card)
        }
        strip.isHidden = g.mode != .row
        listCard.isHidden = g.mode != .list
        styleListCard()
        let host: UIView = g.mode == .row ? strip : (g.mode == .list ? listCard : self)
        for (i, card) in cards.enumerated() {
            guard i < shown, i < products.count else { card.isHidden = true; card.reset(); continue }
            if card.superview !== host { host.addSubview(card) }
            card.isHidden = false
            card.frame = g.cards[i]
            card.configure(products[i], asks: row.asks(products[i]), geometry: g, first: i == 0)
        }
        carouselMetrics = g.carousel
        if let s = g.strip {
            strip.frame = s
            strip.contentSize = CGSize(width: g.stripContent, height: s.height)
            strip.alwaysBounceHorizontal = g.carousel?.isScrollable ?? (g.stripContent > s.width + 1)
            let savedX = Self.offsets[row.rowId] ?? (sameRow ? strip.contentOffset.x : 0)
            let clampedX = g.carousel?.snappedOffset(for: savedX) ?? min(max(0, savedX), max(0, g.stripContent - s.width))
            strip.contentOffset.x = clampedX
            if let metrics = g.carousel {
                arrows?.configure(scrollView: strip, stripFrame: s, yCenter: g.photo / 2, metrics: metrics)
            } else {
                arrows?.hide()
            }
        } else {
            arrows?.hide()
        }
        if let l = g.listCard { listCard.frame = l }
        seeAll.isHidden = g.seeAll == nil
        seeAllRule.isHidden = g.seeAll == nil
        if let s = g.seeAll {
            // A short line under the last row, its words where the rows' names start (as the rows' own rules do).
            let column = 12 + g.photo + 10
            var c = UIButton.Configuration.plain()
            c.title = s.title
            c.baseForegroundColor = ChatPalette.tintText
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: column, bottom: 0, trailing: 12)
            let font = g.fonts.metaStrong
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
            seeAll.configuration = c
            seeAll.contentHorizontalAlignment = .leading
            seeAll.frame = s.frame
            seeAll.accessibilityLabel = row.expanded ? "Show Less" : "Show \(row.count - ProductCardsLayout.listFirst) more"
            seeAllRule.backgroundColor = ChatPalette.separator
            seeAllRule.frame = CGRect(x: column, y: s.frame.minY, width: s.frame.width - column,
                                      height: HQShape.pixel(traitCollection.displayScale))
            listCard.bringSubviewToFront(seeAll)
        }
        while chips.count < g.followUps.count {
            let chip = UIButton(type: .system)
            chip.accessibilityIdentifier = "shopping.followUp"
            chip.addAction(UIAction { [weak self, weak chip] _ in
                guard let text = chip?.configuration?.title else { return }
                Haptics.play(.selection)
                self?.onFollowUp?(text)
            }, for: .primaryActionTriggered)
            #if targetEnvironment(macCatalyst)
            PointerEffects.button(chip)
            #endif
            addSubview(chip)
            chips.append(chip)
        }
        for (i, chip) in chips.enumerated() {
            guard i < g.followUps.count else { chip.isHidden = true; continue }
            let item = g.followUps[i]
            var c = UIButton.Configuration.filled()
            c.baseBackgroundColor = ChatPalette.fill2
            c.baseForegroundColor = ChatPalette.label
            c.cornerStyle = .capsule
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            c.title = item.text
            c.titleLineBreakMode = .byTruncatingTail
            let font = g.fonts.chip
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
            chip.configuration = c
            chip.isHidden = false
            chip.frame = item.frame
        }
        lastShownCount = shown
        lastHasNote = g.note != nil
        lastHasSeeAll = g.seeAll != nil
        lastFollowUpCount = g.followUps.count
        refreshAccessibilityElements()
    }

    private func refreshAccessibilityElements() {
        var elements: [Any] = lastHasNote ? [note] : []
        elements += cards.prefix(lastShownCount).map { $0 as Any }
        elements += arrows?.visibleButtons.map { $0 as Any } ?? []
        if lastHasSeeAll { elements.append(seeAll) }
        elements += chips.prefix(lastFollowUpCount).map { $0 as Any }
        accessibilityElements = elements
    }

    func reset() {
        cards.forEach { $0.reset() }
        carouselMetrics = nil
        arrows?.hide()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isConfiguring, !rowId.isEmpty else { return }
        Self.offsets[rowId] = scrollView.contentOffset.x
        if Self.offsets.count > 200 { Self.offsets = [rowId: scrollView.contentOffset.x] }
        if arrows?.update() == true { refreshAccessibilityElements() }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === strip, let metrics = carouselMetrics, metrics.wholeTiles, metrics.isScrollable else { return }
        targetContentOffset.pointee.x = metrics.snappedOffset(for: targetContentOffset.pointee.x)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === strip, let metrics = carouselMetrics, metrics.wholeTiles, metrics.isScrollable else { return }
        let snapped = metrics.snappedOffset(for: scrollView.contentOffset.x)
        if abs(snapped - scrollView.contentOffset.x) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: snapped, y: 0), animated: !HQMotion.reduced)
        }
    }
}

/// One product: a soft card (single, pair, row) or a list row.
final class ProductCardView: UIControl {
    var onAsk: ((ShoppingCards.Ask) -> Void)?

    private let photo = ShoppingPhotoView()
    private let name = UILabel()
    private let price = UILabel()
    private let meta = UILabel()
    private let rating = UILabel()
    private let accessory = UILabel()
    private let badge = UILabel()
    private let rule = UIView()
    private let button = UIButton(type: .system)
    private var ask: ShoppingCards.Ask = .buy
    private var mode: ProductCardsGeometry.Mode = .pair

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        for label in [name, price, meta, rating, accessory] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        name.textColor = ChatPalette.label
        addSubview(photo)
        badge.textAlignment = .center
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        addSubview(badge)
        rule.isUserInteractionEnabled = false
        addSubview(rule)
        button.accessibilityIdentifier = "shopping.cardBuy"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAsk?(self.ask)   // the chat plays the tap, as for the page's buttons
        }, for: .primaryActionTriggered)
        addSubview(button)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(self)
        PointerEffects.button(button)
        #endif
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the product’s page"
        accessibilityIdentifier = "shopping.card"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ProductCardView, _) in
            view.styleCard(list: view.mode == .list)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func styleCard(list: Bool) {
        backgroundColor = list ? .clear : ChatPalette.promptCard
        layer.cornerRadius = list ? 0 : ChatMetrics.insetCardRadius
        if list {
            layer.borderWidth = 0
            layer.borderColor = nil
        } else {
            let edge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
            layer.borderColor = edge.cgColor
            layer.borderWidth = edge.cgColor.alpha > 0 ? max(HQShape.pixel(traitCollection.displayScale), 1) : 0
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.6) }
    }

    func configure(_ p: ShoppingCards.Product, asks: Set<ShoppingCards.Ask>, geometry g: ProductCardsGeometry, first: Bool) {
        mode = g.mode
        let parts = ProductCardsLayout.parts(g, size: bounds.size, product: p)
        let list = g.mode == .list
        styleCard(list: list)
        clipsToBounds = !list
        photo.frame = parts.photo
        photo.layer.cornerRadius = g.mode == .pair || g.mode == .row ? 0 : 8
        photo.layer.cornerCurve = .continuous
        photo.set(p.image, maxPoints: max(parts.photo.width, parts.photo.height))
        photo.alpha = p.stock == .out ? 0.55 : 1
        name.font = g.fonts.name
        name.text = p.title
        name.frame = parts.name
        price.attributedText = parts.priceText
        price.frame = parts.price
        meta.isHidden = list
        meta.attributedText = parts.metaText
        meta.frame = parts.meta
        rating.isHidden = parts.rating == nil
        rating.attributedText = parts.ratingText
        rating.frame = parts.rating ?? .zero
        accessory.isHidden = parts.accessory == nil
        accessory.attributedText = parts.accessoryText
        accessory.frame = parts.accessory ?? .zero
        // One short pill over the photo's corner: the stock when it can't be bought now, else the bot's badge (a list
        // row carries either at the end of its name line).
        let pill = list ? nil : ProductCardsLayout.photoBadge(p)
        badge.isHidden = pill == nil
        if let pill {
            badge.font = g.fonts.badge
            badge.text = pill.text
            badge.textColor = pill.quiet ? ChatPalette.label : ChatPalette.onTint
            badge.backgroundColor = pill.quiet ? ChatPalette.promptCard : ChatPalette.tint
            let h = ceil(g.fonts.badge.lineHeight) + 6
            let w = min(parts.photo.width - 12, ceil((pill.text as NSString).size(withAttributes: [.font: g.fonts.badge]).width) + 14)
            let inset: CGFloat = g.mode == .single ? 4 : 6
            badge.frame = CGRect(x: parts.photo.minX + inset, y: parts.photo.minY + inset, width: w, height: h)
            badge.layer.cornerRadius = h / 2
        }
        rule.isHidden = !list || first
        rule.backgroundColor = ChatPalette.separator
        let hair = HQShape.pixel(traitCollection.displayScale)
        rule.frame = CGRect(x: parts.name.minX, y: 0, width: bounds.width - parts.name.minX, height: hair)
        // The one product's own button (spec §1: it is the whole answer).
        button.isHidden = parts.button == nil
        if let frame = parts.button {
            let shown = ProductCardsLayout.buttonTitle(p, asks: asks)
            ask = shown.ask
            var c: UIButton.Configuration = shown.done ? .plain() : .filled()
            if !shown.done {
                c.baseBackgroundColor = ChatPalette.tint
                c.baseForegroundColor = ChatPalette.onTint
            } else {
                // What you asked, as the page's quiet line: a tinted check and the words in label 2, not a dimmed button.
                c.baseForegroundColor = ChatPalette.label2
                c.image = UIImage(systemName: "checkmark.circle.fill")
                c.imageColorTransformer = UIConfigurationColorTransformer { _ in ChatPalette.tint }
                c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: g.fonts.button)
                c.imagePadding = 4
            }
            c.cornerStyle = .capsule
            // Once asked, plain words ending where the card's words end (the layout made it as wide as they are).
            c.contentInsets = shown.done ? .zero : NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            c.title = shown.title
            c.titleLineBreakMode = .byTruncatingTail
            let font = g.fonts.button
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
            button.configuration = c
            button.isUserInteractionEnabled = !shown.done
            button.accessibilityTraits = shown.done ? .staticText : .button
            button.frame = frame
        }
        accessibilityLabel = ProductCardsLayout.spokenName(p)
        accessibilityElements = nil
        if !button.isHidden {
            // VoiceOver: the card opens the page; its Buy is a custom action as well as the button.
            let title = button.configuration?.title ?? ""
            accessibilityCustomActions = button.isUserInteractionEnabled ? [UIAccessibilityCustomAction(name: title) { [weak self] _ in
                guard let self else { return false }
                self.onAsk?(self.ask)
                return true
            }] : []
        } else {
            accessibilityCustomActions = []
        }
    }

    func reset() { photo.reset() }
}
