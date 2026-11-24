import UIKit

// [shopping] A product's page (docs/spec/3x-shopping.md §1.2): a glass sheet sized to its content up to large (on the
// Mac and iPad a form sheet, ChatSheet.wrap): the photos, the name, the price, the rating, the options the bot chose,
// one main button (Buy, or Notify Me when out of stock) with a quieter Notify Me of a Price Drop under Buy, Why It
// Fits, Where to Buy and the details. Once you asked, a quiet "Asked to buy" / "Watching" line stands in its place.
// The buttons hand the ask back to the chat (ChatViewController+Shopping.swift), which sends it as your message.

final class ProductPageSheet: UIViewController, UIScrollViewDelegate {
    private let product: ShoppingCards.Product
    private let asks: Set<ShoppingCards.Ask>
    private let onAsk: (ShoppingCards.Ask) -> Void
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let pager = UIScrollView()
    private let dots = UIPageControl()
    private var photos: [ShoppingPhotoView] = []
    private static let photoHeight: CGFloat = 260

    init(product: ShoppingCards.Product, asks: Set<ShoppingCards.Ask>, onAsk: @escaping (ShoppingCards.Ask) -> Void) {
        self.product = product
        self.asks = asks
        self.onAsk = onAsk
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The page in its sheet, from `host` (the chat).
    static func present(_ product: ShoppingCards.Product, asks: Set<ShoppingCards.Ask>, from host: UIViewController,
                        onAsk: @escaping (ShoppingCards.Ask) -> Void) {
        let page = ProductPageSheet(product: product, asks: asks, onAsk: onAsk)
        page.view.accessibilityIdentifier = "shopping.page"
        // Sized to what it holds (a short page stays short), up to large.
        let fit = UISheetPresentationController.Detent.custom(identifier: .init("shopping.page.fit")) { [weak page] context in
            guard let page else { return nil }
            // The bar above the content, and the room under it for the home indicator (as Error Details).
            let wanted = page.fittedHeight(width: page.view.bounds.width > 0 ? page.view.bounds.width : 390) + 64
            return min(context.maximumDetentValue, max(220, wanted))
        }
        let sheet = ChatSheet.wrap(page, title: product.store, detents: [fit, .large()])
        host.present(sheet, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        build()
    }

    #if DEBUG
    /// Screenshots: `-HQDemoShoppingPageScroll <points>` opens the sheet at large and scrolls the page that far.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let y = ChatDemo.argument("-HQDemoShoppingPageScroll").flatMap(Double.init) else { return }
        if let sheet = (navigationController ?? self).sheetPresentationController {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            let most = max(0, self.scroll.contentSize.height + self.scroll.adjustedContentInset.bottom - self.scroll.bounds.height)
            self.scroll.contentOffset.y = min(CGFloat(y) - self.scroll.adjustedContentInset.top, most)
        }
    }
    #endif

    /// The height the page needs at `width` (its own detent reads it).
    func fittedHeight(width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let size = stack.systemLayoutSizeFitting(CGSize(width: max(120, width - 32), height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height) + 8 + 16
    }

    // MARK: Content

    private func build() {
        let p = product
        addPhotos()
        if !p.brand.isEmpty { add(label(p.brand, HQFont.style(.footnote), ChatPalette.label2), after: 2) }
        let title = label(p.title, HQFont.style(.title3, weight: .semibold), ChatPalette.label, lines: 0)
        title.accessibilityTraits = .header
        add(title, after: 4)
        // The price line: the price, the struck list price, the badge.
        let price = UILabel()
        let words = NSMutableAttributedString()
        if let shown = ShoppingCards.priceText(p) {
            words.append(NSAttributedString(string: shown, attributes: [.font: HQFont.style(.title2, weight: .bold), .foregroundColor: ChatPalette.label]))
        }
        if let was = ShoppingCards.wasText(p) {
            if words.length > 0 { words.append(NSAttributedString(string: "  ", attributes: [.font: HQFont.style(.body)])) }
            words.append(NSAttributedString(string: was, attributes: [
                .font: HQFont.style(.body), .foregroundColor: ChatPalette.label3, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        }
        if !p.badge.isEmpty {
            words.append(NSAttributedString(string: (words.length > 0 ? "   " : "") + p.badge,
                                            attributes: [.font: HQFont.style(.footnote, weight: .semibold), .foregroundColor: ChatPalette.tintText]))
        }
        if words.length > 0 {
            price.attributedText = words
            price.numberOfLines = 0
            add(price, after: 2)
        }
        // Rating, stock and delivery on one quiet line.
        var facts: [String] = []
        if let rating = ShoppingCards.ratingText(p.rating, reviews: p.reviews) { facts.append("★ " + rating) }
        if let stock = ShoppingCards.stockText(p.stock) { facts.append(stock) }
        if !p.delivery.isEmpty { facts.append(p.delivery) }
        if !facts.isEmpty { add(label(facts.joined(separator: " · "), HQFont.style(.subheadline), ChatPalette.label2, lines: 0), after: 10) }
        if !p.options.isEmpty {
            add(card(p.options.map { row($0.name, $0.value) }), after: 12)
        }
        addActions()
        if !p.why.isEmpty || !p.caution.isEmpty {
            add(sectionLabel("Why It Fits"), after: 6)
            let lines = p.why.map { bullet($0, symbol: "checkmark.circle.fill", tint: ChatPalette.green) }
                + p.caution.map { bullet($0, symbol: "exclamationmark.triangle.fill", tint: ChatPalette.orange) }
            add(card(lines), after: 14)
        }
        add(sectionLabel("Where to Buy"), after: 6)
        let here = ShoppingCards.Offer(store: p.store, url: p.url, price: p.price, was: p.was, stock: p.stock, delivery: p.delivery)
        // This store's own row is its link: its stock and delivery are on the line under the price already.
        add(card(([here] + p.offers).enumerated().map { offerRow($1, currency: p.currency, quiet: $0 == 0) }), after: 14)
        if !p.specs.isEmpty {
            add(sectionLabel("Details"), after: 6)
            add(card(p.specs.map { row($0.label, $0.value) }), after: 14)
        }
    }

    private func add(_ view: UIView, after spacing: CGFloat) {
        stack.addArrangedSubview(view)
        stack.setCustomSpacing(spacing, after: view)
    }

    private func label(_ text: String, _ font: UIFont, _ color: UIColor, lines: Int = 1) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = color
        l.numberOfLines = lines
        return l
    }

    /// A section's name over its card, as the step sheet and Error Details have theirs.
    private func sectionLabel(_ text: String) -> UILabel {
        let l = label(text, HQFont.preferred(.footnote), ChatPalette.label2)
        l.accessibilityTraits = .header
        return l
    }

    private func addPhotos() {
        let urls = product.images
        // No photo: no box at all; the page starts with the name (the card in the chat shows the placeholder).
        guard !urls.isEmpty else { return }
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: Self.photoHeight).isActive = true
        box.layer.cornerRadius = HQShape.radius(14, .card)
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.frame = box.bounds
        pager.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(pager)
        for _ in urls {
            let photo = ShoppingPhotoView()
            pager.addSubview(photo)
            photos.append(photo)
        }
        dots.numberOfPages = urls.count
        dots.hidesForSinglePage = true
        dots.isUserInteractionEnabled = urls.count > 1
        dots.addAction(UIAction { [weak self] _ in self?.stepPhoto(to: self?.dots.currentPage ?? 0) }, for: .valueChanged)
        dots.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(dots)
        NSLayoutConstraint.activate([dots.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                     dots.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2)])
        if urls.count > 1 {
            let arrows = PhotoPagerArrows(in: box, identifier: "shopping.photo") { [weak self] forward in
                guard let self else { return }
                if let next = PhotoPaging.step(from: self.dots.currentPage, count: self.photos.count, forward: forward) {
                    self.stepPhoto(to: next)
                }
            }
            arrows.update(index: 0, count: urls.count, hidden: false)
            photoArrows = arrows
        }
        box.isAccessibilityElement = urls.count == 1
        box.accessibilityLabel = urls.count == 1 ? "Photo of \(product.title)" : "\(urls.count) photos of \(product.title)"
        add(box, after: 12)
    }

    private var photoArrows: PhotoPagerArrows?

    private func stepPhoto(to page: Int) {
        guard photos.indices.contains(page), pager.bounds.width > 0 else { return }
        dots.currentPage = page
        photoArrows?.update(index: page, count: photos.count, hidden: false)
        pager.setContentOffset(CGPoint(x: CGFloat(page) * pager.bounds.width, y: 0), animated: !HQMotion.reduced)
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (photos.count > 1 ? UIKeyCommand.photoPaging(#selector(stepPhotoKey(_:))) : [])
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func stepPhotoKey(_ command: UIKeyCommand) {
        if let next = PhotoPaging.step(from: dots.currentPage, count: photos.count, forward: command.pagesForward) {
            stepPhoto(to: next)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = pager.bounds.size
        guard size.width > 0 else { return }
        for (i, photo) in photos.enumerated() {
            photo.frame = CGRect(x: CGFloat(i) * size.width, y: 0, width: size.width, height: size.height)
            photo.set(i < product.images.count ? product.images[i] : nil, maxPoints: max(size.width, size.height))
        }
        pager.contentSize = CGSize(width: size.width * CGFloat(photos.count), height: size.height)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.width > 0 else { return }
        let page = max(0, min(photos.count - 1, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
        dots.currentPage = page
        photoArrows?.update(index: page, count: photos.count, hidden: false)
    }

    // MARK: Buy / Notify Me

    private func addActions() {
        if let asked = ShoppingCards.askedText(asks) {
            // Asked already: a quiet line in the buttons' place (one place per action; the message is in the chat).
            let line = UIStackView()
            line.spacing = 6
            line.alignment = .center
            let mark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            mark.tintColor = ChatPalette.tint
            mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: HQFont.style(.subheadline))
            mark.setContentHuggingPriority(.required, for: .horizontal)
            line.addArrangedSubview(mark)
            line.addArrangedSubview(label(asked, HQFont.style(.subheadline, weight: .semibold), ChatPalette.label2))
            line.accessibilityIdentifier = "shopping.asked"
            add(line, after: 18)
            return
        }
        let main: ShoppingCards.Ask = product.buyable ? .buy : .watchStock
        add(button(product.buyable ? "Buy" : "Notify Me", ask: main, filled: true), after: 8)
        if product.buyable, product.price != nil {
            add(button("Notify Me of a Price Drop", ask: .watchPrice, filled: false), after: 18)
        } else if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(18, after: last)
        }
    }

    private func button(_ title: String, ask: ShoppingCards.Ask, filled: Bool) -> UIButton {
        // The sheets' own actions (GlassSheetKit rule 2): the one prominent verb in the accent, the quieter one a
        // card-coloured capsule with the tint's words; both 44 pt, the same on every glass sheet.
        var c: UIButton.Configuration = filled ? .hqSheetProminent() : .hqSheetAction()
        c.title = title
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.ask(ask) })
        b.accessibilityIdentifier = "shopping.\(ask.rawValue.replacingOccurrences(of: " ", with: "-"))"
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(b)
        #endif
        return b
    }

    private func ask(_ ask: ShoppingCards.Ask) {
        let onAsk = onAsk   // the chat plays the tap when it sends
        // The sheet goes down first, so the message is seen landing in the chat.
        (navigationController ?? self).dismiss(animated: true) { onAsk(ask) }
    }

    // MARK: Cards and rows

    /// Rows on one solid card (`HQPalette.sheetCard`, frosted on a glass sheet), hairlines between them.
    private func card(_ rows: [UIView]) -> UIView {
        let box = UIView()
        box.backgroundColor = HQPalette.sheetCard
        box.layer.cornerRadius = HQShape.radius(14, .card)
        box.layer.cornerCurve = .continuous
        box.hqGlassEdge()
        let inner = UIStackView()
        inner.axis = .vertical
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let rule = UIView()
                rule.backgroundColor = ChatPalette.separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: HQShape.pixel(traitCollection.displayScale)).isActive = true
                let holder = UIView()
                holder.addSubview(rule)
                NSLayoutConstraint.activate([rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
                                             rule.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                                             rule.topAnchor.constraint(equalTo: holder.topAnchor),
                                             rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
                inner.addArrangedSubview(holder)
            }
            inner.addArrangedSubview(row)
        }
        return box
    }

    private func padded(_ content: UIView) -> UIView {
        let holder = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
        ])
        return holder
    }

    /// "Colour  Navy", "Weight  1.2 kg".
    private func row(_ name: String, _ value: String) -> UIView {
        let line = UIStackView()
        line.spacing = 12
        let n = label(name, HQFont.style(.subheadline), ChatPalette.label2)
        n.setContentHuggingPriority(.required, for: .horizontal)
        n.setContentCompressionResistancePriority(.required, for: .horizontal)
        let v = label(value, HQFont.style(.subheadline), ChatPalette.label, lines: 0)
        v.textAlignment = .right
        line.addArrangedSubview(n)
        line.addArrangedSubview(v)
        line.isAccessibilityElement = true
        line.accessibilityLabel = "\(name): \(value)"
        return padded(line)
    }

    private func bullet(_ text: String, symbol: String, tint: UIColor) -> UIView {
        let line = UIStackView()
        line.spacing = 10
        line.alignment = .firstBaseline
        let font = HQFont.style(.subheadline)
        let mark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font)))
        mark.tintColor = tint
        mark.setContentHuggingPriority(.required, for: .horizontal)
        line.addArrangedSubview(mark)
        line.addArrangedSubview(label(text, font, ChatPalette.label, lines: 0))
        line.isAccessibilityElement = true
        line.accessibilityLabel = text
        return padded(line)
    }

    /// A store's price: its name and price, its stock or delivery under them; it opens that store's page.
    private func offerRow(_ offer: ShoppingCards.Offer, currency: String, quiet: Bool = false) -> UIView {
        let control = UIControl()
        let words = UIStackView()
        words.axis = .vertical
        words.spacing = 1
        words.isUserInteractionEnabled = false
        let top = UIStackView()
        top.spacing = 8
        top.alignment = .firstBaseline
        // A long name wraps under itself rather than end in "…" (large text, a narrow window).
        let store = label(offer.store, HQFont.style(.subheadline, weight: .semibold), ChatPalette.label, lines: 0)
        top.addArrangedSubview(store)
        let price = UILabel()
        let text = NSMutableAttributedString()
        if let amount = offer.price {
            text.append(NSAttributedString(string: ShoppingCards.price(amount, currency: currency),
                                           attributes: [.font: HQFont.style(.subheadline, weight: .semibold), .foregroundColor: ChatPalette.label]))
        }
        if let was = offer.was {
            text.append(NSAttributedString(string: " ", attributes: [.font: HQFont.style(.footnote)]))
            text.append(NSAttributedString(string: ShoppingCards.price(was, currency: currency), attributes: [
                .font: HQFont.style(.footnote), .foregroundColor: ChatPalette.label3, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        }
        price.attributedText = text
        price.setContentHuggingPriority(.required, for: .horizontal)
        price.setContentCompressionResistancePriority(.required, for: .horizontal)
        top.addArrangedSubview(price)
        let chevron = UIImageView(image: UIImage(systemName: "arrow.up.right", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.style(.footnote, weight: .semibold))))
        chevron.tintColor = ChatPalette.label3
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        top.addArrangedSubview(chevron)
        words.addArrangedSubview(top)
        let under = [ShoppingCards.stockText(offer.stock), offer.delivery.isEmpty ? nil : offer.delivery].compactMap { $0 }
        if !under.isEmpty, !quiet { words.addArrangedSubview(label(under.joined(separator: " · "), HQFont.style(.footnote), ChatPalette.label2)) }
        let holder = padded(words)
        holder.isUserInteractionEnabled = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(holder)
        NSLayoutConstraint.activate([holder.topAnchor.constraint(equalTo: control.topAnchor), holder.bottomAnchor.constraint(equalTo: control.bottomAnchor),
                                     holder.leadingAnchor.constraint(equalTo: control.leadingAnchor), holder.trailingAnchor.constraint(equalTo: control.trailingAnchor)])
        let url = offer.url
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.play(.selection)
            LinkOpener.open(url, from: self)
        }, for: .touchUpInside)   // a plain UIControl never sends .primaryActionTriggered
        control.isAccessibilityElement = true
        control.accessibilityTraits = .link
        control.accessibilityLabel = ([offer.store, offer.price.map { ShoppingCards.price($0, currency: currency) }].compactMap { $0 } + under).joined(separator: ", ")
        return control
    }
}
