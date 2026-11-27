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
    var noteLines: Int { big ? 4 : 2 }
    var chipHeight: CGFloat { Self.line(chip) + 14 }

    static func line(_ font: UIFont) -> CGFloat { ceil(font.lineHeight) }

    /// The height of `text` in `font` at `width`: whole lines, at most `maxLines` of them.
    static func height(_ text: String, _ font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let box = (text as NSString).boundingRect(with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        let lines = max(1, min(maxLines, Int((box.height / max(1, font.lineHeight)).rounded())))
        return CGFloat(lines) * line(font)
    }

    /// A row of follow-up chips that scrolls sideways.
    @MainActor static func chips(_ texts: [String], type: TravelCardType, action: @escaping (String) -> Void) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.heightAnchor.constraint(equalToConstant: type.chipHeight).isActive = true
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let font = type.chip
        for text in texts {
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
            btn.addAction(UIAction { _ in action(text) }, for: .primaryActionTriggered)
            row.addArrangedSubview(btn)
        }
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    /// `view` at exactly `height` in a card's stack.
    @MainActor static func pinned(_ view: UIView, _ height: CGFloat) -> UIView {
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
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
        if !f.followUps.isEmpty { p.chips = type.chipHeight }
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = FlightsCardLayout.cardGap
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reset() {
        row = nil
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    func configure(_ card: FlightsCardRow, _ g: FlightsCardGeometry) {
        row = card
        stack.frame = CGRect(x: FlightsCardLayout.side, y: g.gapAbove, width: g.width, height: g.height)
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let f = card.flights
        let type = TravelCardType(category: g.category)
        let p = FlightsCardLayout.pieces(card, width: g.width, category: g.category)
        if !f.step.isEmpty {
            let pill = UILabel()
            pill.text = "  \(f.step)  "
            pill.font = type.smallStrong
            pill.textColor = ChatPalette.tintText
            pill.accessibilityIdentifier = "travel.flights.step"
            stack.addArrangedSubview(TravelCardType.pinned(pill, p.step))
        }
        if !f.note.isEmpty {
            let note = UILabel()
            note.text = f.note
            note.font = type.body
            note.textColor = ChatPalette.label2
            note.numberOfLines = type.noteLines
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
            stack.addArrangedSubview(TravelCardType.pinned(makeFlightRow(f.flights[idx], index: idx, card: card, type: type), p.row))
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
            more.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(TravelCardType.pinned(more, p.more))
        }

        if !f.followUps.isEmpty {
            stack.addArrangedSubview(TravelCardType.chips(f.followUps, type: type) { [weak self] text in self?.onFollowUp?(text) })
        }
    }

    private func makeFlightRow(_ flight: TravelCards.Flight, index: Int, card: FlightsCardRow, type: TravelCardType) -> UIView {
        let control = UIControl()
        control.backgroundColor = ChatPalette.botBubble
        control.layer.cornerRadius = ChatMetrics.insetCardRadius
        control.layer.cornerCurve = .continuous
        control.layer.borderWidth = HQShape.hairline
        control.layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
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
                label(bagSummary.isEmpty ? "Tap for bags, changes & refund rules" : bagSummary, type.small, ChatPalette.label2),
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
    var height: CGFloat
    var gapAbove: CGFloat
    var category: UIContentSizeCategory
}

nonisolated enum HotelsCardLayout {
    static let side: CGFloat = 16
    static let photoHeight: CGFloat = 118

    /// The height of each piece of the card, top to bottom (0: not there). The view pins each piece to the same number.
    struct Pieces {
        var step: CGFloat = 0, meta: CGFloat = 0, note: CGFloat = 0, carousel: CGFloat = 0, chips: CGFloat = 0
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

    /// Lines a hotel's name may take on its tile.
    static func nameLines(_ type: TravelCardType) -> Int { type.big ? 2 : 1 }

    /// A tile: the photo, then the name, where it is and the price.
    static func tileHeight(_ type: TravelCardType) -> CGFloat {
        let line = TravelCardType.line
        return photoHeight + 8 + line(type.title) * CGFloat(nameLines(type)) + line(type.small) + line(type.bodyStrong) + 2 * 3 + 10
    }

    static func tileWidth(count: Int, width: CGFloat, type: TravelCardType) -> CGFloat {
        count == 1 ? width : min(type.big ? 300 : 224, max(180, width * (type.big ? 0.8 : 0.68)))
    }

    static func pieces(_ card: HotelsCardRow, width: CGFloat, category: UIContentSizeCategory) -> Pieces {
        let type = TravelCardType(category: category)
        let model = card.hotels
        var p = Pieces()
        if !model.step.isEmpty { p.step = TravelCardType.line(type.smallStrong) }
        let meta = metaWords(model)
        if !meta.isEmpty { p.meta = TravelCardType.height(meta, type.smallStrong, width: width, maxLines: type.big ? 3 : 1) }
        if !model.note.isEmpty { p.note = TravelCardType.height(model.note, type.body, width: width, maxLines: type.noteLines) }
        p.carousel = tileHeight(type)
        if !model.followUps.isEmpty { p.chips = type.chipHeight }
        return p
    }

    static func make(_ card: HotelsCardRow, gap: CGFloat, width: CGFloat, category: UIContentSizeCategory) -> RowLayout {
        let cardW = PromptLayout.cardWidth(for: width)
        let hModel = card.hotels
        let inner = ceil(pieces(card, width: cardW, category: category).height)
        let geo = HotelsCardGeometry(width: cardW, height: inner, gapAbove: gap + 6, category: category)
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

final class HotelsCardView: UIView {
    var onOpenHotel: ((Int) -> Void)?
    var onFollowUp: ((String) -> Void)?

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reset() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    func configure(_ card: HotelsCardRow, _ g: HotelsCardGeometry) {
        stack.frame = CGRect(x: HotelsCardLayout.side, y: g.gapAbove, width: g.width, height: g.height)
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let model = card.hotels
        let type = TravelCardType(category: g.category)
        let p = HotelsCardLayout.pieces(card, width: g.width, category: g.category)
        if !model.step.isEmpty {
            let lbl = UILabel()
            lbl.text = model.step
            lbl.font = type.smallStrong
            lbl.textColor = ChatPalette.tintText
            stack.addArrangedSubview(TravelCardType.pinned(lbl, p.step))
        }
        let meta = HotelsCardLayout.metaWords(model)
        if !meta.isEmpty {
            let lbl = UILabel()
            lbl.text = meta
            lbl.font = type.smallStrong
            lbl.textColor = ChatPalette.label2
            lbl.numberOfLines = type.big ? 3 : 1
            stack.addArrangedSubview(TravelCardType.pinned(lbl, p.meta))
        }
        if !model.note.isEmpty {
            let lbl = UILabel()
            lbl.text = model.note
            lbl.font = type.body
            lbl.textColor = ChatPalette.label2
            lbl.numberOfLines = type.noteLines
            stack.addArrangedSubview(TravelCardType.pinned(lbl, p.note))
        }

        let carousel = UIScrollView()
        carousel.showsHorizontalScrollIndicator = false
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        let itemW = HotelsCardLayout.tileWidth(count: model.hotels.count, width: g.width, type: type)
        for (idx, hotel) in model.hotels.enumerated() {
            rowStack.addArrangedSubview(makeHotelTile(hotel, index: idx, width: itemW, asked: card.asks(hotel), type: type))
        }
        carousel.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: carousel.contentLayoutGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: carousel.contentLayoutGuide.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: carousel.contentLayoutGuide.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: carousel.contentLayoutGuide.bottomAnchor),
            rowStack.heightAnchor.constraint(equalTo: carousel.frameLayoutGuide.heightAnchor),
        ])
        stack.addArrangedSubview(TravelCardType.pinned(carousel, p.carousel))

        if !model.followUps.isEmpty {
            stack.addArrangedSubview(TravelCardType.chips(model.followUps, type: type) { [weak self] text in self?.onFollowUp?(text) })
        }
    }

    private func makeHotelTile(_ hotel: TravelCards.Hotel, index: Int, width: CGFloat, asked: Set<TravelCards.Ask>, type: TravelCardType) -> UIView {
        let tile = UIControl()
        tile.backgroundColor = ChatPalette.botBubble
        tile.layer.cornerRadius = ChatMetrics.insetCardRadius
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = HQShape.hairline
        tile.layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
        tile.clipsToBounds = true
        tile.widthAnchor.constraint(equalToConstant: width).isActive = true
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .button
        let priceWords = hotel.pricePerNight.map { ShoppingCards.price($0, currency: hotel.currency) + " per night" } ?? ""
        tile.accessibilityLabel = [hotel.name, hotel.neighborhood, priceWords].filter { !$0.isEmpty }.joined(separator: ", ")
        tile.accessibilityIdentifier = "travel.hotel.\(index)"
        tile.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onOpenHotel?(index)
        }, for: .touchUpInside)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(tile)
        #endif

        let photo = ShoppingPhotoView()
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.isUserInteractionEnabled = false
        photo.set(hotel.image, maxPoints: max(width, 220))
        tile.addSubview(photo)

        let nameLabel = UILabel()
        nameLabel.text = hotel.name
        nameLabel.font = type.title
        nameLabel.textColor = ChatPalette.label
        nameLabel.numberOfLines = HotelsCardLayout.nameLines(type)
        nameLabel.lineBreakMode = .byTruncatingTail

        let sub = [
            hotel.rating.map { String(format: "★ %.1f", $0) },
            hotel.neighborhood.isEmpty ? nil : hotel.neighborhood,
        ].compactMap { $0 }.joined(separator: " · ")
        let subLabel = UILabel()
        subLabel.text = sub.isEmpty ? hotel.address : sub
        subLabel.font = type.small
        subLabel.textColor = ChatPalette.label2
        subLabel.lineBreakMode = .byTruncatingTail

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
