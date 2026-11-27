import UIKit

// [shopping] The order card (docs/spec/3x-shopping.md §1.4, §2.2): a bot at the last step of a checkout shows what it
// is about to buy: the store, the items, the charges, the total, where it goes and how it is paid. Nothing is paid
// without Pay: Cancel and "Pay $140.39" sit inside the card, as a draft card's buttons do. Once answered (or
// replaced by a newer order) the card says what happened instead. The card wears every chat card's shell (a reply
// bubble's fill, a round mark and a title), so its text and marks are drawn by the prompt cell from
// `OrderCardLayout`; only its two buttons are this file's own view.

// MARK: - Layout

nonisolated struct OrderCardGeometry: @unchecked Sendable {
    struct ItemHit: Sendable, Hashable {
        var index: Int
        var frame: CGRect
        var title: String
    }
    /// Cancel and Pay, in the row's coordinates (none once the card is settled).
    var buttons: [(ShoppingCards.OrderAnswer, CGRect)]
    /// Tappable line items (multi-product or URL-backed order items) in row coordinates.
    var items: [ItemHit] = []
    var payTitle: String
    var font: UIFont
    var stacked: Bool
}

nonisolated enum OrderCardLayout {
    static let side: CGFloat = 16, padH: CGFloat = 14, padV: CGFloat = 12

    static func title(_ o: ShoppingCards.Order) -> String { "Order at \(o.store)" }
    static func payTitle(_ o: ShoppingCards.Order) -> String { "Pay \(ShoppingCards.totalText(o))" }

    /// "−$5.00" for a discount, "$10.40" for a charge, "Free" for nothing.
    static func amount(_ value: Double, _ currency: String) -> String {
        if value == 0 { return "Free" }
        let text = ShoppingCards.price(abs(value), currency: currency)
        return value < 0 ? "−" + text : text
    }

    /// "Ship to", "Pay with", "Arrives": the lines under the total that the bot gave.
    static func details(_ o: ShoppingCards.Order) -> [(label: String, value: String)] {
        var out: [(String, String)] = []
        let ship = [o.shipName, o.shipAddress].filter { !$0.isEmpty }.joined(separator: ", ")
        if !ship.isEmpty { out.append(("Ship to", ship)) }
        if !o.payWith.isEmpty { out.append(("Pay with", o.payWith)) }
        if !o.arrives.isEmpty { out.append(("Arrives", o.arrives)) }
        return out
    }

    static func make(_ card: OrderCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let o = card.order
        let cardW = PromptLayout.cardWidth(for: width), innerW = cardW - 2 * padH
        let top = gap + 6, x = side + padH
        let settled = card.state != .waiting
        let head = PromptLayout.noteHeader(title(o), glyph: "bag.circle.fill", dim: card.state == .cancelled || card.state == .replaced,
                                           x: x, y: top + padV, width: innerW, category: category)
        var texts = [head.text], symbols = [head.symbol], rules: [CGRect] = []
        var spoken = [title(o)]
        var y = head.maxY + 10
        let body = PromptFonts.font(.subheadline, category)
        let small = PromptFonts.font(.footnote, category)
        let amountFont = PromptFonts.tabular(.subheadline, category)
        let ink = settled ? ChatPalette.label2 : ChatPalette.label

        /// A line with words at the leading edge and an amount at the trailing edge; the words take one line.
        func line(_ words: String, _ font: UIFont, _ color: UIColor, amount: String?, amountFont: UIFont, amountColor: UIColor, trailingReserve: CGFloat = 0) {
            var right: CGFloat = trailingReserve
            if let amount {
                let a = TextKitLayout(PromptLayout.text(amount, amountFont, amountColor), width: nil)
                let ax = x + innerW - trailingReserve - a.size.width
                right = a.size.width + 10 + trailingReserve
                texts.append(PromptPlacedText(text: a, frame: CGRect(x: ax, y: y, width: a.size.width, height: a.size.height)))
            }
            let (w, _) = PromptLayout.clamped(PromptLayout.text(words, font, color), width: max(40, innerW - right), maxLines: 1)
            texts.append(PromptPlacedText(text: w, frame: CGRect(x: x, y: y, width: max(40, innerW - right), height: w.size.height)))
            y += max(w.size.height, ceil(font.lineHeight))
        }

        var itemHits: [OrderCardGeometry.ItemHit] = []
        let chevronSide: CGFloat = 12
        for (index, item) in o.items.enumerated() {
            let itemTop = y
            let openable = card.openableItems.contains(index)
            let reserve: CGFloat = openable ? (chevronSide + 6) : 0
            let price = item.price.map { ShoppingCards.price($0, currency: o.currency) }
            line("\(item.qty) × \(item.title)", body, openable && !settled ? ChatPalette.tintText : ink,
                 amount: price, amountFont: amountFont, amountColor: ink, trailingReserve: reserve)
            if !item.detail.isEmpty {
                let (d, _) = PromptLayout.clamped(PromptLayout.text(item.detail, small, ChatPalette.label2), width: max(40, innerW - reserve), maxLines: 1)
                texts.append(PromptPlacedText(text: d, frame: CGRect(x: x, y: y, width: max(40, innerW - reserve), height: d.size.height)))
                y += d.size.height
            }
            if openable {
                let itemHeight = max(32, y - itemTop)
                let midY = itemTop + itemHeight / 2
                symbols.append(PromptSymbol(frame: CGRect(x: x + innerW - chevronSide, y: midY - chevronSide / 2, width: chevronSide, height: chevronSide),
                                            name: "chevron.right", style: .quiet))
                let hitFrame = CGRect(x: x - 6, y: itemTop - 3, width: innerW + 12, height: max(36, y - itemTop + 6))
                itemHits.append(OrderCardGeometry.ItemHit(index: index, frame: hitFrame, title: item.title))
            }
            y += 4
            spoken.append(["\(item.qty) \(item.title)", item.detail, price ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        if !o.charges.isEmpty {
            y += 2
            for charge in o.charges {
                let shown = amount(charge.amount, o.currency)
                line(charge.label, small, ChatPalette.label2, amount: shown, amountFont: PromptFonts.tabular(.footnote, category),
                     amountColor: ChatPalette.label2)
                y += 2
                spoken.append("\(charge.label) \(shown)")
            }
        }
        y += 6
        rules.append(CGRect(x: x, y: y, width: innerW, height: 0))
        y += 8
        let total = ShoppingCards.totalText(o)
        let strong = PromptFonts.font(.body, category, weight: .semibold)
        line("Total", strong, ink, amount: total, amountFont: HQFont.monoDigitFace(ofSize: strong.pointSize, weight: .semibold), amountColor: ink)
        spoken.append("Total \(total)")
        // Ship to, Pay with, Arrives: a label column, as a letter's header on the draft card.
        let details = details(o)
        if !details.isEmpty {
            y += 8
            let over = category.isAccessibilityCategory
            let labelW = over ? 0 : ceil(details.map { ($0.label as NSString).size(withAttributes: [.font: small]).width }.max() ?? 0) + 10
            for d in details {
                let label = TextKitLayout(PromptLayout.text(d.label, small, ChatPalette.label2), width: nil)
                texts.append(PromptPlacedText(text: label, frame: CGRect(x: x, y: y, width: label.size.width, height: label.size.height)))
                if over { y += label.size.height }
                let (value, _) = PromptLayout.clamped(PromptLayout.text(d.value, small, ChatPalette.label), width: innerW - labelW, maxLines: 2)
                texts.append(PromptPlacedText(text: value, frame: CGRect(x: x + labelW, y: y, width: innerW - labelW, height: value.size.height)))
                y += max(value.size.height, over ? 0 : label.size.height) + 3
                spoken.append("\(d.label): \(d.value)")
            }
        }
        if !o.note.isEmpty {
            y += 4
            let (n, _) = PromptLayout.clamped(PromptLayout.text(o.note, small, ChatPalette.label2), width: innerW, maxLines: 3)
            texts.append(PromptPlacedText(text: n, frame: CGRect(x: x, y: y, width: innerW, height: n.size.height)))
            y += n.size.height
            spoken.append(o.note)
        }

        // The foot: Cancel and Pay while it waits; what happened once it doesn't.
        var placed: [(ShoppingCards.OrderAnswer, CGRect)] = []
        let font = PromptFonts.button(category)
        var stacked = false
        let pay = payTitle(o)
        if let status = ShoppingCards.status(card.state, o) {
            let statusFont = PromptFonts.font(.footnote, category, weight: .semibold, cap: 24)
            let mark = ceil(min(24, max(15, statusFont.pointSize * 1.15)))
            let lineH = ceil(statusFont.lineHeight), first = max(lineH, mark)
            y += 10
            let s = TextKitLayout(PromptLayout.text(status, statusFont, ChatPalette.label2), width: innerW - mark - 6)
            texts.append(PromptPlacedText(text: s, frame: CGRect(x: x + mark + 6, y: y + (first - lineH) / 2, width: s.size.width, height: s.size.height)))
            let approved = card.state == .approved
            symbols.append(PromptSymbol(frame: CGRect(x: x, y: y + (first - mark) / 2, width: mark, height: mark),
                                        name: approved ? "checkmark.circle.fill" : (card.state == .replaced ? "arrow.triangle.2.circlepath.circle" : "minus.circle"),
                                        style: approved ? .picked : .blank))
            y += max(first, s.size.height + (first - lineH) / 2)
            spoken.append(status)
        } else {
            let order: [ShoppingCards.OrderAnswer] = [.cancel, .pay]
            let h = max(44, ceil(font.lineHeight) + 16)
            let widths = [title(for: .cancel, pay: pay), pay].map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 32 }
            stacked = category.isAccessibilityCategory || widths.reduce(0, +) + 8 > innerW
            y += 12
            if stacked {
                for b in order.reversed() {
                    placed.append((b, CGRect(x: x, y: y, width: innerW, height: h)))
                    y += h + 8
                }
                y -= 8
            } else {
                var right = x + innerW
                for (b, w) in zip(order, widths).reversed() {
                    right -= w
                    placed.append((b, CGRect(x: right, y: y, width: w, height: h)))
                    right -= 8
                }
                y += h
            }
        }
        let cardFrame = CGRect(x: side, y: top, width: cardW, height: ceil(y + padV - top))
        let layout = PromptRowLayout(cardFrame: cardFrame, texts: texts, approval: nil, symbols: symbols, rules: rules,
                                     shopping: .order(OrderCardGeometry(buttons: placed, items: itemHits, payTitle: pay, font: font, stacked: stacked)),
                                     accessibility: spoken.joined(separator: ". "))
        return RowLayout(height: ceil(cardFrame.maxY + 6), content: .prompt(layout))
    }

    static func title(for answer: ShoppingCards.OrderAnswer, pay: String) -> String { answer == .pay ? pay : "Cancel" }
}

// MARK: - View

/// The order card's clickable line items, Cancel and Pay (the cell places it over the whole row; touches elsewhere pass through).
final class OrderCardButtons: UIView {
    var onTap: ((ShoppingCards.OrderAnswer) -> Void)?
    var onOpenItem: ((Int) -> Void)?
    private var buttons: [ShoppingCards.OrderAnswer: UIButton] = [:]
    private var itemControls: [UIControl] = []
    private(set) var ordered: [UIView] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func configure(_ g: OrderCardGeometry) {
        var shown = Set<ShoppingCards.OrderAnswer>()
        var actionButtons: [UIButton] = []
        for (kind, frame) in g.buttons {
            let button = buttons[kind] ?? make(kind)
            buttons[kind] = button
            button.isHidden = false
            button.frame = frame
            button.configuration = config(kind, title: OrderCardLayout.title(for: kind, pay: g.payTitle), font: g.font)
            shown.insert(kind)
            actionButtons.append(button)
        }
        for (kind, button) in buttons where !shown.contains(kind) { button.isHidden = true }
        // VoiceOver reads Pay first, as the stacked layout shows it.
        if !g.stacked { actionButtons.reverse() }

        while itemControls.count < g.items.count {
            let control = makeItemControl()
            itemControls.append(control)
        }
        var activeItems: [UIControl] = []
        for (slot, hit) in g.items.enumerated() {
            let control = itemControls[slot]
            control.isHidden = false
            control.frame = hit.frame
            control.tag = hit.index
            control.accessibilityLabel = "Open \(hit.title)"
            control.accessibilityIdentifier = "order.item.\(hit.index)"
            activeItems.append(control)
        }
        for slot in g.items.count..<itemControls.count { itemControls[slot].isHidden = true }
        ordered = activeItems + actionButtons
    }

    private func makeItemControl() -> UIControl {
        let control = UIControl()
        control.layer.cornerRadius = 8
        control.layer.cornerCurve = .continuous
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
        addSubview(control)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(control)
        #endif
        return control
    }

    @objc private func itemTapped(_ sender: UIControl) {
        onOpenItem?(sender.tag)
    }

    private func make(_ kind: ShoppingCards.OrderAnswer) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "order.\(kind.rawValue)"
        button.addAction(UIAction { [weak self] _ in self?.onTap?(kind) }, for: .primaryActionTriggered)
        addSubview(button)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(button)
        #endif
        return button
    }

    private func config(_ kind: ShoppingCards.OrderAnswer, title: String, font: UIFont) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .pay:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = ChatPalette.onTint
        case .cancel:
            c = .plain()
            c.baseForegroundColor = ChatPalette.label2
        }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        c.title = title
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = font; return a }
        return c
    }
}
