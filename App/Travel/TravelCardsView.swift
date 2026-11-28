// [travel] Native UIKit cards for Flights (`show_flights`) and Hotels (`show_hotels`) inside the chat transcript.
// Exact height calculation off-main-thread so 120 Hz scrolling stays rock-solid.

import UIKit

// MARK: - Type and sizes

/// The cards' fonts and line heights at a text size. The layout (off the main thread) and the views read the same
/// ones, so what is measured is what is drawn: a card grows with the text instead of squeezing a line (the price) out.
nonisolated struct TravelCardType {
    let category: UIContentSizeCategory
    /// Accessibility text sizes: a flight's price gets a line of its own and names may take two lines.
    var big: Bool { category.isAccessibilityCategory }
    var title: UIFont { PromptFonts.font(.subheadline, category, weight: .semibold, cap: 26) }
    var price: UIFont { PromptFonts.font(.subheadline, category, weight: .bold, cap: 26) }
    var body: UIFont { PromptFonts.font(.footnote, category, cap: 24) }
    var bodyStrong: UIFont { PromptFonts.font(.footnote, category, weight: .semibold, cap: 24) }
    var small: UIFont { PromptFonts.font(.caption1, category, cap: 22) }
    var smallStrong: UIFont { PromptFonts.font(.caption1, category, weight: .semibold, cap: 22) }
    var badge: UIFont { PromptFonts.font(.caption2, category, weight: .semibold, cap: 20) }
    var chip: UIFont { PromptFonts.font(.footnote, category, weight: .medium, cap: 24) }
    /// Lines a note above the cards may take.
    var noteLines: Int { big ? 4 : 3 }
    var chipHeight: CGFloat { max(32, Self.line(chip) + 14) }

    static func line(_ font: UIFont) -> CGFloat { ceil(font.lineHeight) }

    /// Whole lines `text` takes in `font` at `width`, capped at `maxLines`.
    /// Measured with TextKit (`NSLayoutManager` + `NSTextContainer`) so line wrapping matches `UILabel` on both iOS and Mac.
    static func lineCount(_ text: String, _ font: UIFont, width: CGFloat, maxLines: Int) -> Int {
        guard !text.isEmpty, maxLines > 0 else { return 0 }
        let measureW = max(40, width - 2)
        let attributed = PromptLayout.text(text, font, ChatPalette.label)
        let (layout, _) = PromptLayout.clamped(attributed, width: measureW, maxLines: maxLines)
        return max(1, min(maxLines, PromptLayout.lineCount(layout)))
    }

    /// The height of `text` in `font` at `width`: whole lines, at most `maxLines` of them.
    static func height(_ text: String, _ font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, maxLines > 0 else { return 0 }
        let measureW = max(40, width - 2)
        let attributed = PromptLayout.text(text, font, ChatPalette.label)
        let (layout, _) = PromptLayout.clamped(attributed, width: measureW, maxLines: maxLines)
        let count = max(1, min(maxLines, PromptLayout.lineCount(layout)))
        return max(ceil(layout.size.height), CGFloat(count) * line(font))
    }

    /// Multi-line wrapped layout for follow-up chips so chips never clip off-edge on Mac or narrow panes.
    static func chipLayout(_ texts: [String], width: CGFloat, type: TravelCardType) -> (frames: [(text: String, frame: CGRect)], height: CGFloat) {
        guard !texts.isEmpty else { return ([], 0) }
        let chipH = type.chipHeight
        let font = type.chip
        let gap: CGFloat = 6
        let maxW = max(80, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var placed: [(String, CGRect)] = []
        for text in texts {
            let w = min(maxW, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 28)
            if x > 0, x + w > maxW {
                x = 0
                y += chipH + gap
            }
            placed.append((text, CGRect(x: x, y: y, width: w, height: chipH)))
            x += w + gap
        }
        return (placed, y + chipH)
    }

    /// Wrapped rows of follow-up chips with Mac pointer feedback.
    @MainActor static func chips(_ texts: [String], width: CGFloat, type: TravelCardType, action: @escaping (String) -> Void) -> UIView {
        let laid = chipLayout(texts, width: width, type: type)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: laid.height))
        let font = type.chip
        for (text, frame) in laid.frames {
            let btn = UIButton(type: .system)
            var cfg = UIButton.Configuration.tinted()
            cfg.title = text
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            cfg.titleLineBreakMode = .byTruncatingTail
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var out = a; out.font = font; return out
            }
            btn.configuration = cfg
            btn.frame = frame
            btn.addAction(UIAction { _ in
                Haptics.play(.selection)
                action(text)
            }, for: .primaryActionTriggered)
            #if targetEnvironment(macCatalyst)
            PointerEffects.button(btn)
            #endif
            container.addSubview(btn)
        }
        return container
    }

    /// `view` at exactly `height` in a card's stack.
    @MainActor static func pinned(_ view: UIView, _ height: CGFloat) -> UIView {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

/// Interactive card tile control used for flight rows and hotel tiles: dims on iOS press, keeps crisp hover/press fill on Mac.
private final class TravelCardControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (control: TravelCardControl, _) in
            control.applyCardChrome()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.6) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyCardChrome() }
    }

    func applyCardChrome(traits: UITraitCollection? = nil) {
        let resolved = traits ?? traitCollection
        backgroundColor = ChatPalette.promptCard
        layer.cornerRadius = ChatMetrics.insetCardRadius
        layer.cornerCurve = .continuous
        let edge = ChatPalette.promptEdge.resolvedColor(with: resolved)
        layer.borderColor = edge.cgColor
        layer.borderWidth = edge.cgColor.alpha > 0 ? max(HQShape.pixel(resolved.displayScale), 1) : 0
    }
}

// MARK: - Flights Card Layout & View

nonisolated struct FlightsCardGeometry: @unchecked Sendable {
    var width: CGFloat
    var height: CGFloat
    var gapAbove: CGFloat
    var category: UIContentSizeCategory
}

nonisolated enum FlightsCardLayout {
    static let side: CGFloat = 16
    static let cardGap: CGFloat = 8
    /// Flights shown before "N more".
    static let shown = 4

    /// The height of each piece of the card, top to bottom (0: not there). The view pins each piece to the same number.
    struct Pieces {
        var step: CGFloat = 0, note: CGFloat = 0, relaxed: CGFloat = 0
        var row: CGFloat = 0, rows = 0
        var more: CGFloat = 0, chips: CGFloat = 0
        var height: CGFloat {
            let all = ([step, note, relaxed] + Array(repeating: row, count: rows) + [more, chips]).filter { $0 > 0 }
            return all.reduce(0, +) + CGFloat(max(0, all.count - 1)) * FlightsCardLayout.cardGap
        }
    }

    static func relaxedWords(_ flights: TravelCards.Flights) -> String { "Relaxed filters: \(flights.relaxedFilters.joined(separator: ", "))" }

    /// One flight's row: three lines beside the price; at accessibility sizes the times, the route, two lines of
    /// details and the price each on their own line.
    static func rowHeight(_ type: TravelCardType) -> CGFloat {
        let line = TravelCardType.line
        if type.big { return line(type.title) * 2 + line(type.body) * 2 + line(type.price) + 4 * 3 + 22 }
        return max(76, line(type.title) + line(type.body) + line(type.small) + 2 * 2 + 22)
    }

    static func pieces(_ card: FlightsCardRow, width: CGFloat, category: UIContentSizeCategory) -> Pieces {
        let type = TravelCardType(category: category)
        let f = card.flights
        var p = Pieces()
        if !f.step.isEmpty { p.step = TravelCardType.line(type.smallStrong) }
        if !f.note.isEmpty { p.note = TravelCardType.height(f.note, type.body, width: width, maxLines: type.noteLines) }
        if !f.relaxedFilters.isEmpty {
            p.relaxed = TravelCardType.height(relaxedWords(f), type.smallStrong, width: width - 20, maxLines: type.noteLines) + 12
        }
        p.rows = card.expanded ? f.flights.count : min(shown, f.flights.count)
        p.row = rowHeight(type)
        if f.flights.count > shown { p.more = max(30, TravelCardType.line(type.bodyStrong) + 10) }
        if !f.followUps.isEmpty { p.chips = TravelCardType.chipLayout(f.followUps, width: width, type: type).height }
        return p
    }

    static func make(_ card: FlightsCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let cardW = PromptLayout.cardWidth(for: width)
        let f = card.flights
        let inner = ceil(pieces(card, width: cardW, category: category).height)
        let geo = FlightsCardGeometry(width: cardW, height: inner, gapAbove: gap + 6, category: category)
        let layout = PromptRowLayout(
            cardFrame: nil,
            texts: [],
            approval: nil,
            travel: .flights(geo),
            accessibility: "\(f.flights.count) flights"
        )
        return RowLayout(height: ceil(gap + 6 + inner + 8), content: .prompt(layout))
    }
}

final class FlightsCardView: UIView {
    var onOpenFlight: ((Int) -> Void)?
    var onBookFlight: ((Int) -> Void)?
    var onFollowUp: ((String) -> Void)?
    var onToggle: (() -> Void)?

    private let stack = UIStackView()
    private var row: FlightsCardRow?
    private var flightControls: [TravelCardControl] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = FlightsCardLayout.cardGap
        addSubview(stack)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: FlightsCardView, _) in
            view.restyleCards()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reset() {
        row = nil
        flightControls.removeAll()
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    private func restyleCards() {
        for control in flightControls { control.applyCardChrome(traits: traitCollection) }
    }

    func configure(_ card: FlightsCardRow, _ g: FlightsCardGeometry) {
        row = card
        flightControls.removeAll()
        stack.frame = CGRect(x: FlightsCardLayout.side, y: g.gapAbove, width: g.width, height: g.height)
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let f = card.flights
        let type = TravelCardType(category: g.category)
        let p = FlightsCardLayout.pieces(card, width: g.width, category: g.category)
        if !f.step.isEmpty {
            let pill = UILabel()
            pill.text = f.step
            pill.font = type.smallStrong
            pill.textColor = ChatPalette.tintText
            pill.lineBreakMode = .byTruncatingTail
            pill.accessibilityIdentifier = "travel.flights.step"
            stack.addArrangedSubview(TravelCardType.pinned(pill, p.step))
        }
        if !f.note.isEmpty {
            let note = UILabel()
            note.text = f.note
            note.font = type.body
            note.textColor = ChatPalette.label2
            note.numberOfLines = type.noteLines
            note.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(TravelCardType.pinned(note, p.note))
        }
        if !f.relaxedFilters.isEmpty {
            let banner = UIView()
            banner.backgroundColor = ChatPalette.fill4
            banner.layer.cornerRadius = 10
            banner.layer.cornerCurve = .continuous
            let lbl = UILabel()
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.text = FlightsCardLayout.relaxedWords(f)
            lbl.font = type.smallStrong
            lbl.textColor = ChatPalette.label2
            lbl.numberOfLines = type.noteLines
            lbl.accessibilityIdentifier = "travel.flights.relaxed"
            banner.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
                lbl.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
                lbl.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            ])
            stack.addArrangedSubview(TravelCardType.pinned(banner, p.relaxed))
        }

        for idx in 0..<p.rows {
            let control = makeFlightRow(f.flights[idx], index: idx, card: card, type: type)
            flightControls.append(control)
            stack.addArrangedSubview(TravelCardType.pinned(control, p.row))
        }

        if f.flights.count > FlightsCardLayout.shown {
            let more = UIButton(type: .system)
            let hidden = f.flights.count - FlightsCardLayout.shown
            var cfg = UIButton.Configuration.plain()
            cfg.title = card.expanded ? "Show Less" : "\(hidden) more ›"
            cfg.baseForegroundColor = ChatPalette.tintText
            let font = type.bodyStrong
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var out = a; out.font = font; return out
            }
            more.configuration = cfg
            more.contentHorizontalAlignment = .leading
            more.accessibilityIdentifier = "travel.flights.toggle"
            more.addAction(UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.onToggle?()
            }, for: .primaryActionTriggered)
            #if targetEnvironment(macCatalyst)
            PointerEffects.button(more)
            #endif
            stack.addArrangedSubview(TravelCardType.pinned(more, p.more))
        }

        if !f.followUps.isEmpty {
            let chips = TravelCardType.chips(f.followUps, width: g.width, type: type) { [weak self] text in self?.onFollowUp?(text) }
            stack.addArrangedSubview(TravelCardType.pinned(chips, p.chips))
        }
    }

    private func makeFlightRow(_ flight: TravelCards.Flight, index: Int, card: FlightsCardRow, type: TravelCardType) -> TravelCardControl {
        let control = TravelCardControl()
        control.applyCardChrome(traits: traitCollection)
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = "\(flight.airline), \(flight.routeLabel), \(flight.departTime) to \(flight.arriveTime), \(flight.stopsLabel), \(ShoppingCards.price(flight.price, currency: flight.currency))"
        control.accessibilityIdentifier = "travel.flight.\(index)"
        control.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onOpenFlight?(index)
        }, for: .touchUpInside)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(control)
        #endif

        func label(_ text: String, _ font: UIFont, _ color: UIColor, lines: Int = 1) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = font
            l.textColor = color
            l.numberOfLines = lines
            l.lineBreakMode = .byTruncatingTail
            // The words give way, never the price beside them.
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return l
        }
        let times = "\(flight.departTime) – \(flight.arriveTime)"
        let details = [flight.airline, flight.duration, flight.stopsLabel, flight.fareTier.isEmpty ? flight.cabin : flight.fareTier]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        let priceLabel = UILabel()
        priceLabel.text = ShoppingCards.price(flight.price, currency: flight.currency)
        priceLabel.font = type.price
        priceLabel.textColor = ChatPalette.label

        let statusLabel = UILabel()
        statusLabel.font = type.badge
        if card.asks(flight).contains(.book) {
            statusLabel.text = "Requested"
            statusLabel.textColor = ChatPalette.label2
        } else if !flight.badge.isEmpty {
            statusLabel.text = flight.badge
            statusLabel.textColor = ChatPalette.tintText
        } else {
            statusLabel.text = "Details ›"
            statusLabel.textColor = ChatPalette.tintText
        }
        statusLabel.lineBreakMode = .byTruncatingTail
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)

        let rowStack: UIStackView
        if type.big {
            // Accessibility sizes: every fact on a line of its own, the price last.
            let priceLine = UIStackView(arrangedSubviews: [priceLabel, statusLabel])
            priceLine.axis = .horizontal
            priceLine.alignment = .firstBaseline
            priceLine.spacing = 10
            statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rowStack = UIStackView(arrangedSubviews: [
                label(times, type.title, ChatPalette.label), label(flight.routeLabel, type.title, ChatPalette.label),
                label(details, type.body, ChatPalette.label2, lines: 2), priceLine,
            ])
            rowStack.axis = .vertical
            rowStack.alignment = .leading
            rowStack.spacing = 3
        } else {
            let bagSummary = [flight.carryOn, flight.refundRule].filter { !$0.isEmpty }.joined(separator: " · ")
            let leftStack = UIStackView(arrangedSubviews: [
                label("\(times)  ·  \(flight.routeLabel)", type.title, ChatPalette.label),
                label(details, type.body, ChatPalette.label2),
                label(bagSummary.isEmpty ? "\(DeviceWord.Tap) for bags, changes & refund rules" : bagSummary, type.small, ChatPalette.label2),
            ])
            leftStack.axis = .vertical
            leftStack.spacing = 2
            priceLabel.textAlignment = .right
            statusLabel.textAlignment = .right
            statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let rightStack = UIStackView(arrangedSubviews: [priceLabel, statusLabel])
            rightStack.axis = .vertical
            rightStack.spacing = 3
            rightStack.alignment = .trailing
            rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)
            rightStack.setContentHuggingPriority(.required, for: .horizontal)
            rowStack = UIStackView(arrangedSubviews: [leftStack, rightStack])
            rowStack.axis = .horizontal
            rowStack.alignment = .center
            rowStack.spacing = 10
        }
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.isUserInteractionEnabled = false
        control.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -12),
            rowStack.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        return control
    }
}

// MARK: - Hotels Card Layout & View

nonisolated struct HotelsCardGeometry: @unchecked Sendable {
    var width: CGFloat
    var rowWidth: CGFloat
    var height: CGFloat
    var gapAbove: CGFloat
    var category: UIContentSizeCategory
}

nonisolated enum HotelsCardLayout {
    static let side: CGFloat = 16
    static let photoHeight: CGFloat = 118
    static let tileSpacing: CGFloat = 10

    /// The height of each piece of the card, top to bottom (0: not there). The view pins each piece to the same number.
    struct Pieces {
        var step: CGFloat = 0, meta: CGFloat = 0, note: CGFloat = 0, carousel: CGFloat = 0, chips: CGFloat = 0
        var nameLines: Int = 1
        var hasSubtitle: Bool = false
        var height: CGFloat {
            let all = [step, meta, note, carousel, chips].filter { $0 > 0 }
            return all.reduce(0, +) + CGFloat(max(0, all.count - 1)) * 8
        }
    }

    /// "Manhattan, NY · Dec 12 – Dec 15 · 2 guests".
    static func metaWords(_ model: TravelCards.Hotels) -> String {
        [model.location, [model.checkIn, model.checkOut].filter { !$0.isEmpty }.joined(separator: " – "), model.guests]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Lines the metadata header above the cards may take.
    static func metaLines(_ type: TravelCardType) -> Int { type.big ? 4 : 3 }

    /// Lines a hotel's name may take on its tile.
    static func nameLines(_ type: TravelCardType) -> Int { type.big ? 3 : 2 }

    /// Secondary line on a hotel tile: rating + neighborhood, else address, distance, or star class.
    static func subtitle(_ hotel: TravelCards.Hotel) -> String {
        let primary = [
            hotel.rating.map { String(format: "★ %.1f", $0) },
            hotel.neighborhood.isEmpty ? nil : hotel.neighborhood,
        ].compactMap { $0 }.joined(separator: " · ")
        if !primary.isEmpty { return primary }
        if !hotel.address.isEmpty { return hotel.address }
        if !hotel.distance.isEmpty { return hotel.distance }
        if let stars = hotel.stars { return "\(stars)-star" }
        return ""
    }

    /// Actual lines needed for hotel names in this strip (1 when all names fit on 1 line, up to `nameLines(type)`).
    static func measuredNameLines(_ hotels: [TravelCards.Hotel], itemWidth: CGFloat, type: TravelCardType) -> Int {
        let limit = nameLines(type)
        let textW = max(40, itemWidth - 20)
        return hotels.map { TravelCardType.lineCount($0.name, type.title, width: textW, maxLines: limit) }.max() ?? 1
    }

    /// A tile: the photo, then the name, optional subtitle, and the price.
    static func tileHeight(_ type: TravelCardType, nameLines: Int? = nil, hasSubtitle: Bool = true) -> CGFloat {
        let line = TravelCardType.line
        let lines = nameLines ?? Self.nameLines(type)
        let subH = hasSubtitle ? line(type.small) + 3 : 0
        return photoHeight + 8 + line(type.title) * CGFloat(lines) + subH + line(type.bodyStrong) + 3 + 10
    }

    static func tileWidth(count: Int, width: CGFloat, type: TravelCardType) -> CGFloat {
        count == 1 ? width : min(type.big ? 300 : 224, max(180, width * (type.big ? 0.8 : 0.68)))
    }

    /// Carousel viewport & whole-tile sizing: bleeds edge-to-edge on narrow phones; fits exact whole tiles on Mac wide panes.
    static func carouselMetrics(count: Int, rowWidth: CGFloat, cardWidth: CGFloat, type: TravelCardType,
                                wholeTiles: Bool = DeviceWord.isMac) -> ChatCarouselMetrics {
        let phoneTile = min(type.big ? 300 : 224, max(180, cardWidth * (type.big ? 0.8 : 0.68)))
        return ChatCarouselMetrics.compute(
            count: count,
            rowWidth: rowWidth,
            cardWidth: cardWidth,
            side: side,
            spacing: tileSpacing,
            phoneTileWidth: phoneTile,
            minWideTile: type.big ? 280 : 200,
            maxWideTile: type.big ? 340 : 260,
            singleWideCap: type.big ? 420 : 360,
            wholeTiles: wholeTiles
        )
    }

    /// True on phone/narrow columns where the card spans the full row width so the carousel can bleed edge-to-edge.
    static func bleedsCarousel(rowWidth: CGFloat, cardWidth: CGFloat) -> Bool {
        ChatCarouselMetrics.bleeds(rowWidth: rowWidth, cardWidth: cardWidth, side: side)
    }

    static func pieces(_ card: HotelsCardRow, width: CGFloat, rowWidth: CGFloat? = nil, category: UIContentSizeCategory,
                       wholeTiles: Bool = DeviceWord.isMac) -> Pieces {
        let type = TravelCardType(category: category)
        let model = card.hotels
        var p = Pieces()
        if !model.step.isEmpty { p.step = TravelCardType.line(type.smallStrong) }
        let meta = metaWords(model)
        if !meta.isEmpty { p.meta = TravelCardType.height(meta, type.smallStrong, width: width, maxLines: metaLines(type)) }
        if !model.note.isEmpty { p.note = TravelCardType.height(model.note, type.body, width: width, maxLines: type.noteLines) }
        let metrics = carouselMetrics(count: model.hotels.count, rowWidth: rowWidth ?? (width + 2 * side), cardWidth: width, type: type, wholeTiles: wholeTiles)
        let itemW = metrics.tileWidth > 0 ? metrics.tileWidth : tileWidth(count: model.hotels.count, width: width, type: type)
        p.nameLines = measuredNameLines(model.hotels, itemWidth: itemW, type: type)
        p.hasSubtitle = model.hotels.contains { !subtitle($0).isEmpty }
        p.carousel = tileHeight(type, nameLines: p.nameLines, hasSubtitle: p.hasSubtitle)
        if !model.followUps.isEmpty { p.chips = TravelCardType.chipLayout(model.followUps, width: width, type: type).height }
        return p
    }

    static func make(_ card: HotelsCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let cardW = PromptLayout.cardWidth(for: width)
        let hModel = card.hotels
        let inner = ceil(pieces(card, width: cardW, rowWidth: width, category: category).height)
        let geo = HotelsCardGeometry(width: cardW, rowWidth: width, height: inner, gapAbove: gap + 6, category: category)
        let layout = PromptRowLayout(
            cardFrame: nil,
            texts: [],
            approval: nil,
            travel: .hotels(geo),
            accessibility: "\(hModel.hotels.count) hotels"
        )
        return RowLayout(height: ceil(gap + 6 + inner + 8), content: .prompt(layout))
    }
}

final class HotelsCardView: UIView, UIScrollViewDelegate {
    var onOpenHotel: ((Int) -> Void)?
    var onFollowUp: ((String) -> Void)?

    private var managedSubviews: [UIView] = []
    private var tileControls: [TravelCardControl] = []
    private let carousel = UIScrollView()
    private var arrows: ChatCarouselArrows?
    private var carouselMetrics: ChatCarouselMetrics?
    private var rowId = ""
    private var isConfiguring = false
    /// Where each hotel strip was scrolled to, by row: cell reuse keeps its place.
    private static var offsets: [String: CGFloat] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        carousel.showsHorizontalScrollIndicator = false
        carousel.clipsToBounds = true
        carousel.delegate = self
        #if targetEnvironment(macCatalyst)
        carousel.delaysContentTouches = false
        #endif
        addSubview(carousel)
        arrows = ChatCarouselArrows(in: self, identifier: "travel.hotels", itemNoun: "hotels") { [weak self] forward in
            self?.stepCarousel(forward: forward)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: HotelsCardView, _) in
            view.restyleTiles()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reset() {
        for view in managedSubviews { view.removeFromSuperview() }
        managedSubviews.removeAll()
        for tile in tileControls { tile.removeFromSuperview() }
        tileControls.removeAll()
        carouselMetrics = nil
        arrows?.hide()
    }

    private func restyleTiles() {
        for tile in tileControls { tile.applyCardChrome(traits: traitCollection) }
        arrows?.restyle()
    }

    private func stepCarousel(forward: Bool) {
        guard let metrics = carouselMetrics else { return }
        let targetX = metrics.steppedOffset(from: carousel.contentOffset.x, forward: forward)
        carousel.setContentOffset(CGPoint(x: targetX, y: 0), animated: !HQMotion.reduced)
        if HQMotion.reduced { arrows?.update() }
    }

    func configure(_ card: HotelsCardRow, _ g: HotelsCardGeometry) {
        isConfiguring = true
        defer { isConfiguring = false }
        let sameRow = rowId == card.rowId
        rowId = card.rowId

        for view in managedSubviews { view.removeFromSuperview() }
        managedSubviews.removeAll()
        for tile in tileControls { tile.removeFromSuperview() }
        tileControls.removeAll()

        let model = card.hotels
        let type = TravelCardType(category: g.category)
        let p = HotelsCardLayout.pieces(card, width: g.width, rowWidth: g.rowWidth, category: g.category)
        let metrics = HotelsCardLayout.carouselMetrics(count: model.hotels.count, rowWidth: g.rowWidth, cardWidth: g.width, type: type)
        carouselMetrics = metrics
        let side = HotelsCardLayout.side
        var y = g.gapAbove

        func place(_ view: UIView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: width, height: height)
            addSubview(view)
            managedSubviews.append(view)
            y += height + 8
        }

        if p.step > 0 {
            let lbl = UILabel()
            lbl.text = model.step
            lbl.font = type.smallStrong
            lbl.textColor = ChatPalette.tintText
            lbl.lineBreakMode = .byTruncatingTail
            place(lbl, x: side, width: g.width, height: p.step)
        }
        let meta = HotelsCardLayout.metaWords(model)
        if p.meta > 0 {
            let lbl = UILabel()
            lbl.text = meta
            lbl.font = type.smallStrong
            lbl.textColor = ChatPalette.label2
            lbl.numberOfLines = HotelsCardLayout.metaLines(type)
            lbl.lineBreakMode = .byTruncatingTail
            place(lbl, x: side, width: g.width, height: p.meta)
        }
        if p.note > 0 {
            let lbl = UILabel()
            lbl.text = model.note
            lbl.font = type.body
            lbl.textColor = ChatPalette.label2
            lbl.numberOfLines = type.noteLines
            lbl.lineBreakMode = .byTruncatingTail
            place(lbl, x: side, width: g.width, height: p.note)
        }

        let stripFrame = CGRect(x: metrics.stripX, y: y, width: metrics.stripWidth, height: p.carousel)
        carousel.frame = stripFrame
        carousel.alwaysBounceHorizontal = metrics.isScrollable
        for (idx, hotel) in model.hotels.enumerated() {
            let tile = makeHotelTile(hotel, index: idx, width: metrics.tileWidth, nameLines: p.nameLines, asked: card.asks(hotel), type: type)
            tile.frame = CGRect(
                x: metrics.contentInset + CGFloat(idx) * metrics.stride,
                y: 0,
                width: metrics.tileWidth,
                height: p.carousel
            )
            carousel.addSubview(tile)
            tileControls.append(tile)
        }
        carousel.contentSize = CGSize(width: metrics.contentWidth, height: p.carousel)
        let savedX = Self.offsets[card.rowId] ?? (sameRow ? carousel.contentOffset.x : 0)
        carousel.contentOffset = CGPoint(x: metrics.snappedOffset(for: savedX), y: 0)
        arrows?.configure(scrollView: carousel, stripFrame: stripFrame, yCenter: HotelsCardLayout.photoHeight / 2, metrics: metrics)
        y += p.carousel + 8

        if p.chips > 0 {
            let chips = TravelCardType.chips(model.followUps, width: g.width, type: type) { [weak self] text in self?.onFollowUp?(text) }
            place(chips, x: side, width: g.width, height: p.chips)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === carousel, !isConfiguring, !rowId.isEmpty else { return }
        Self.offsets[rowId] = scrollView.contentOffset.x
        if Self.offsets.count > 200 { Self.offsets = [rowId: scrollView.contentOffset.x] }
        arrows?.update()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === carousel, let metrics = carouselMetrics, metrics.wholeTiles, metrics.isScrollable else { return }
        targetContentOffset.pointee.x = metrics.snappedOffset(for: targetContentOffset.pointee.x)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === carousel, let metrics = carouselMetrics, metrics.wholeTiles, metrics.isScrollable else { return }
        let snapped = metrics.snappedOffset(for: scrollView.contentOffset.x)
        if abs(snapped - scrollView.contentOffset.x) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: snapped, y: 0), animated: !HQMotion.reduced)
        }
    }

    private func makeHotelTile(_ hotel: TravelCards.Hotel, index: Int, width: CGFloat, nameLines: Int, asked: Set<TravelCards.Ask>, type: TravelCardType) -> TravelCardControl {
        let tile = TravelCardControl()
        tile.applyCardChrome(traits: traitCollection)
        tile.clipsToBounds = true
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .button
        let priceWords = hotel.pricePerNight.map { ShoppingCards.price($0, currency: hotel.currency) + " per night" } ?? ""
        tile.accessibilityLabel = [hotel.name, hotel.neighborhood, priceWords].filter { !$0.isEmpty }.joined(separator: ", ")
        tile.accessibilityIdentifier = "travel.hotel.\(index)"
        tile.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onOpenHotel?(index)
        }, for: .touchUpInside)

        let photo = ShoppingPhotoView()
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.isUserInteractionEnabled = false
        photo.set(hotel.image, maxPoints: max(width, 220))
        tile.addSubview(photo)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(tile, above: photo)
        #endif

        let nameLabel = UILabel()
        nameLabel.text = hotel.name
        nameLabel.font = type.title
        nameLabel.textColor = ChatPalette.label
        nameLabel.numberOfLines = nameLines
        nameLabel.lineBreakMode = .byTruncatingTail

        let subText = HotelsCardLayout.subtitle(hotel)
        let subLabel = UILabel()
        subLabel.text = subText
        subLabel.font = type.small
        subLabel.textColor = ChatPalette.label2
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.isHidden = subText.isEmpty

        let priceLabel = UILabel()
        if let nightly = hotel.pricePerNight {
            priceLabel.text = "\(ShoppingCards.price(nightly, currency: hotel.currency))/nt"
                + (asked.contains(.book) ? " · Requested" : (hotel.hasCoordinates ? " · Map" : ""))
        } else {
            priceLabel.text = hotel.hasCoordinates ? "View map & details" : "View details"
        }
        priceLabel.font = type.bodyStrong
        priceLabel.textColor = ChatPalette.tintText
        priceLabel.lineBreakMode = .byTruncatingTail

        let infoStack = UIStackView(arrangedSubviews: [nameLabel, subLabel, priceLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 3
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.isUserInteractionEnabled = false
        tile.addSubview(infoStack)

        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: tile.topAnchor),
            photo.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            photo.heightAnchor.constraint(equalToConstant: HotelsCardLayout.photoHeight),

            infoStack.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 8),
            infoStack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            infoStack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -8),
        ])
        return tile
    }
}
