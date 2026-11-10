// [transcript] The Table page (docs/spec/3x-transcript.md §3.4, row L309; the web's `ui-chat/table-sheet.tsx`): a
// table from a reply on its own page, with "Copy as Text" giving its rows as tab-separated text (what Numbers and a
// spreadsheet paste into cells).
//
// Rebuilt 2026-10-29 (owner: the expanded table "just needs to be a lot better"). It reads like a spreadsheet: the
// words above the table name the page; the columns fill the screen, wrapping their words, when they can all fit
// (Fit to Screen, on by default; off, each column is as wide as its words and the page scrolls sideways); the header
// row stays at the top and, on a page that scrolls sideways, the first column stays at the left; a tap on a header
// sorts by that column (numbers by value), again the other way, a third time back to the reply's order; a tap on a row
// marks it, to follow it across; a hold on a cell copies it, its row or its column; a long table can be searched.
// The share menu copies the table as Markdown or CSV, or shares a CSV file.

import UIKit

final class TableSheetController: UIViewController, UIScrollViewDelegate, UISearchResultsUpdating, UIContextMenuInteractionDelegate {
    private let table: MarkdownTable
    /// Every row's cells as plain words, header first.
    let rows: [[String]]
    private let columns: Int

    /// The column the rows are sorted by, nil = the reply's order.
    private(set) var sort: (column: Int, ascending: Bool)?
    private(set) var query = ""
    /// Fit to Screen: columns share the page's width, wrapping their words, when they can all fit. Until it is picked
    /// in the ⋯ menu the page chooses: fitted, unless that would break most short cells (names, numbers) onto more
    /// lines and the first column can stay pinned while the rest scroll, the way a spreadsheet reads.
    private(set) var fitted = true
    private var fitPicked = false
    /// The marked row (a body row's index in the reply's order).
    private(set) var marked: Int?
    /// The body rows shown, in the order shown (indices in the reply's order).
    private(set) var order: [Int] = []

    private let scroll = UIScrollView()
    private let content = UIView()
    /// The body's cells (all but a frozen first column's), its row lines and the marked row.
    private let bodyLayer = UIView()
    private let bodyLines = TableSheetRowsView()
    /// A frozen first column's body cells: they stay at the left as the page scrolls sideways.
    private let columnLayer = UIView()
    private let columnLines = TableSheetRowsView()
    /// The header row: it stays at the top as the page scrolls down.
    private let headerLayer = UIView()
    /// A frozen first column's header cell: it stays at the top left.
    private let cornerLayer = UIView()
    private let headerRule = UIView()
    private let columnRule = UIView()
    private let empty = UILabel()
    private let failure = UILabel()
    private var copyItem: UIBarButtonItem!
    private var shareItem: UIBarButtonItem!
    private var moreItem: UIBarButtonItem!
    private var restore: DispatchWorkItem?

    /// Cells by row (0 = header, then the body in the reply's order) and column.
    private var cells: [[TableSheetCell]] = []
    /// Each cell's text in its column's alignment, at the page's sizes.
    private var texts: [[NSAttributedString]] = []
    private var naturalWidths: [CGFloat] = []
    private var minimumWidths: [CGFloat] = []
    /// Each body cell's words on one line, for the choice above.
    private var cellWidths: [[CGFloat]] = []
    private var naturalHeights: [CGFloat] = []
    private var builtFor: UIContentSizeCategory?
    private var laidFor: (width: CGFloat, fitted: Bool)?

    // The last layout, in content coordinates.
    private var widths: [CGFloat] = []
    private var xs: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var headerHeight: CGFloat = 0
    private var gridSize: CGSize = .zero
    private(set) var frozen = false
    /// The table is wider than the page but its columns can share it, wrapping (Fit to Screen has something to do).
    private(set) var canFit = false

    /// [mac] Opened inside the chat's own pane (pushed, with Back), not as a sheet (`open(_:from:)`).
    private var inPane = false
    /// [mac-ui-issues] A spreadsheet file in the Mac's file window (`MacFileWindow.viewer`): the bar's extra buttons
    /// (Open in Numbers, the sheet picker), the share menu's extra commands (the file itself), the sheet's name and the
    /// rows the whole sheet has when only its first are shown.
    var fileItems: [UIBarButtonItem] = []
    var fileShare: [UIMenuElement] = []
    var fileSheet: String?
    var fileRows: Int?

    /// The table page for a file's sheet: laid out as in the chat's pane (a card under the window's bar).
    static func filePage(_ table: MarkdownTable) -> TableSheetController {
        let page = TableSheetController(table: table)
        page.inPane = true
        page.title = page.titles.title
        page.navigationItem.largeTitleDisplayMode = .never
        return page
    }

    static let copyTitle = "Copy as Text"
    static let copiedTitle = "Copied"
    /// Search shows from this many body rows.
    static let searchFrom = 8

    private static let edge: CGFloat = 16
    private static let padH: CGFloat = 12
    private static let padV: CGFloat = 11
    private static let headerPadV: CGFloat = 9
    private static let sortRoom: CGFloat = 16

    init(table: MarkdownTable) {
        self.table = table
        self.rows = table.words
        self.columns = table.columnCount
        super.init(nibName: nil, bundle: nil)
        order = Array(table.rows.indices)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `table` from `screen`. [mac] Owner 2026-11-08 ("when opening a table … it feels like we never even tried, and
    /// when you close the pop-up, it moves the entire app window down"): a sheet sized to the table (up to 900 × 900) was
    /// taller than a laptop's window, so macOS moved the window for it and left it there. On the Mac the table opens in
    /// the pane the chat is in, its whole width and height, with Back (⌘[, Escape) to the chat; elsewhere the sheet.
    static func open(_ table: MarkdownTable, from screen: UIViewController) {
        #if targetEnvironment(macCatalyst)
        if let navigation = screen.navigationController {
            // [mac-ui-issues] Owner 2026-11-09 ("it opens it into a page and then opens another page of the same thing.
            // So you have to click back twice"): a click on Expand reached both the button and the bubble's own click,
            // and each pushed a page. One table page at a time: a second ask while one is on top (or on its way) is dropped.
            if navigation.topViewController is TableSheetController || navigation.viewControllers.contains(where: { $0 is TableSheetController }) { return }
            let page = TableSheetController(table: table)
            page.inPane = true
            page.title = page.titles.title
            page.navigationItem.largeTitleDisplayMode = .never
            navigation.pushViewController(page, animated: true)
            return
        }
        #endif
        guard screen.presentedViewController == nil else { return }   // [mac-ui-issues] one sheet, as one page above
        screen.present(make(table), animated: true)
    }

    /// The sheet, ready to present: titled with the words that name the table (else "Table"), large, closed by the
    /// sheet's own close button.
    static func make(_ table: MarkdownTable) -> UINavigationController {
        let page = TableSheetController(table: table)
        let navigation = ChatSheet.wrap(page, title: page.titles.title, detents: [.large()])
        navigation.setToolbarHidden(false, animated: false)
        return navigation
    }

    /// The page's title and subtitle: the caption (a bracketed end moving to the subtitle: "Rep by rep" over
    /// "minimum 40 orders · 7 rows · 4 columns"), else "Table"; the subtitle counts the rows (those shown while
    /// searching) and columns.
    var titles: (title: String, subtitle: String) {
        var title = table.caption ?? "Table"
        var aside: String?
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
            let inner = title[open.upperBound..<title.index(before: title.endIndex)]
            let head = title[..<open.lowerBound]
            if head.count >= 2, !inner.isEmpty {
                aside = String(inner)
                title = String(head)
            }
        }
        let total = table.rows.count
        var rowsWord = query.isEmpty ? "\(total) \(total == 1 ? "row" : "rows")" : "\(order.count) of \(total) rows"
        if let fileRows, fileRows > total, query.isEmpty {
            rowsWord = "first \(total.formatted()) of \(fileRows.formatted()) rows"
        }
        if aside == nil { aside = fileSheet }
        let counts = "\(rowsWord) · \(columns) \(columns == 1 ? "column" : "columns")"
        return (title, [aside, counts].compactMap { $0 }.joined(separator: " · "))
    }

    // MARK: Building

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ChatPalette.page
        view.accessibilityIdentifier = "table.sheet"
        navigationItem.subtitle = titles.subtitle

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.delegate = self
        scroll.accessibilityLabel = "Table contents"
        scroll.accessibilityHint = "Scroll across the table or copy its rows as tab-separated text."
        scroll.accessibilityIdentifier = "table.sheet.contents"
        view.addSubview(scroll)
        scroll.addSubview(content)
        // Back to front: the body, the frozen column, the header row, the corner, then the two rules over them all.
        for layer in [bodyLayer, columnLayer, headerLayer, cornerLayer, headerRule, columnRule] { content.addSubview(layer) }
        bodyLayer.addSubview(bodyLines)
        columnLayer.addSubview(columnLines)
        columnLayer.backgroundColor = ChatPalette.page
        for layer in [headerLayer, cornerLayer] {
            layer.backgroundColor = ChatPalette.page
            let band = UIView(frame: layer.bounds)
            band.backgroundColor = ChatPalette.fill4
            band.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            band.isUserInteractionEnabled = false
            layer.addSubview(band)
        }
        for layer in [headerLayer, columnLayer, cornerLayer] {
            layer.layer.shadowColor = UIColor.black.cgColor
            layer.layer.shadowRadius = 6
            layer.layer.shadowOpacity = 0
        }
        headerLayer.layer.shadowOffset = CGSize(width: 0, height: 2)
        columnLayer.layer.shadowOffset = CGSize(width: 2, height: 0)
        cornerLayer.layer.shadowOffset = CGSize(width: 1, height: 1)
        headerRule.backgroundColor = ChatPalette.separator
        columnRule.backgroundColor = ChatPalette.separator

        empty.font = HQFont.preferred(.subheadline)
        empty.adjustsFontForContentSizeCategory = true
        empty.textColor = ChatPalette.label2
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.isHidden = true
        empty.accessibilityIdentifier = "table.sheet.empty"
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)

        failure.text = TableText.failure
        failure.textColor = ChatPalette.red
        failure.numberOfLines = 0
        failure.font = HQFont.preferred(.footnote)
        failure.adjustsFontForContentSizeCategory = true
        failure.isHidden = true
        failure.accessibilityIdentifier = "table.sheet.failure"
        failure.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failure)
        if inPane { placeCard() }
        NSLayoutConstraint.activate((inPane ? [] : [
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]) + [
            empty.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            empty.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failure.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            failure.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        scroll.addInteraction(UIContextMenuInteraction(delegate: self))

        copyItem = UIBarButtonItem(title: Self.copyTitle, style: .prominent, target: self, action: #selector(copyTapped))
        copyItem.accessibilityIdentifier = "table.sheet.copy"
        shareItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), menu: nil)
        shareItem.accessibilityLabel = "Share"
        shareItem.accessibilityIdentifier = "table.sheet.share"
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #67: a plain glyph like the bar's ⋯, set on the item itself: the toolbar hooks
        // (`DesktopBars.prepare`) never reached the items the sheet's navigation controller places, and Share stayed a
        // round glass bubble. Copy as Text keeps its capsule.
        shareItem.hidesSharedBackground = true
        #endif
        toolbarItems = [shareItem, .flexibleSpace(), copyItem, .flexibleSpace()]
        moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        moreItem.accessibilityLabel = "Table Options"
        moreItem.accessibilityIdentifier = "table.sheet.more"
        navigationItem.rightBarButtonItems = (navigationItem.rightBarButtonItems ?? []) + [moreItem]
        if inPane {
            // [mac] In the chat's pane: the commands in its bar, as a Mac window's toolbar (⋯ last), no bottom bar.
            copyItem.style = .plain
            navigationItem.rightBarButtonItems = [moreItem, shareItem, copyItem] + fileItems
            toolbarItems = nil
        }

        if table.rows.count >= Self.searchFrom {
            let search = UISearchController(searchResultsController: nil)
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            search.hidesNavigationBarDuringPresentation = false
            search.searchBar.placeholder = "Search \(table.rows.count) Rows"
            search.searchBar.accessibilityIdentifier = "table.sheet.search"
            navigationItem.searchController = search
            PageSearchField.hidesOnScroll(navigationItem)
            navigationItem.preferredSearchBarPlacement = .stacked
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (page: TableSheetController, _) in
            page.view.setNeedsLayout()
        }
        buildCells()
        refreshMenus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if builtFor != traitCollection.preferredContentSizeCategory { buildCells() }
        if laidFor?.width != available || laidFor?.fitted != fitted { layoutGrid() }
        if inPane { fitCard(lane: scroll.contentInset.bottom) }   // [mac] a taller or shorter window
    }

    /// The width the columns can fill: the page less its safe area at the sides.
    private var available: CGFloat {
        if inPane { return max(200, cardRoom.width) }   // [mac] the card's widest, not its width now (it hugs the table)
        return max(200, scroll.bounds.width - scroll.adjustedContentInset.left - scroll.adjustedContentInset.right)
    }

    // MARK: [mac] In the chat's pane

    /// The card's margin from the pane's edges and bar.
    private static let cardMargin: CGFloat = 24
    private var cardWidth: NSLayoutConstraint?
    private var cardHeight: NSLayoutConstraint?

    /// The most the card may take: the pane less its margins (under the bar).
    private var cardRoom: CGSize {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        return CGSize(width: safe.width - 2 * Self.cardMargin, height: safe.height - Self.cardMargin * 1.5)
    }

    /// In the pane the table is a card, as a reply's table is: set in from the edges, as big as the table up to the
    /// pane, a rounded outline round it; the header and a frozen first column still hold inside it as it scrolls.
    private func placeCard() {
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.layer.cornerRadius = HQShape.radius(12, .card)
        scroll.layer.cornerCurve = .continuous
        scroll.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        scroll.layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
        scroll.clipsToBounds = true
        let width = scroll.widthAnchor.constraint(equalToConstant: 400), height = scroll.heightAnchor.constraint(equalToConstant: 300)
        cardWidth = width; cardHeight = height
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.cardMargin * 0.75),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Self.cardMargin),
            width, height,
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (page: TableSheetController, _) in
            page.scroll.layer.borderColor = ChatPalette.separator.resolvedColor(with: page.traitCollection).cgColor
        }
    }

    /// The card hugs the grid, up to the room the pane gives.
    private func fitCard(lane: CGFloat) {
        guard inPane, let cardWidth, let cardHeight else { return }
        let room = cardRoom
        let size = CGSize(width: min(gridSize.width, room.width), height: min(gridSize.height + lane, room.height))
        if abs(cardWidth.constant - size.width) > 0.5 { cardWidth.constant = size.width }
        if abs(cardHeight.constant - size.height) > 0.5 { cardHeight.constant = size.height }
    }

    private var bodyFont: UIFont { HQFont.scaled(15, like: .subheadline) }
    private var headFont: UIFont { HQFont.scaled(13, weight: .semibold, like: .footnote) }

    /// Every cell's text at the page's sizes (the reply's bold, code and links kept; digits all one width, so numbers
    /// line up), measured for its column's natural and narrowest (longest word) widths.
    private func buildCells() {
        let category = traitCollection.preferredContentSizeCategory
        builtFor = category
        laidFor = nil
        cells.joined().forEach { $0.removeFromSuperview() }
        cells = []; texts = []; naturalHeights = []; cellWidths = []
        guard columns > 0 else { return }
        let all = [table.header] + table.rows
        let cap: CGFloat = category.isAccessibilityCategory ? 420 : 280
        naturalWidths = Array(repeating: 24, count: columns)
        minimumWidths = Array(repeating: 24, count: columns)
        for (r, row) in all.enumerated() {
            let header = r == 0
            var line: [TableSheetCell] = [], drawn: [NSAttributedString] = [], lineWidths: [CGFloat] = []
            var tallest: CGFloat = ceil((header ? headFont : bodyFont).lineHeight)
            for c in 0..<columns {
                let source = c < row.count ? row[c] : NSAttributedString()
                let natural = restyled(source, header: header, alignment: .natural)
                drawn.append(restyled(source, header: header, alignment: table.alignment(c)))
                let room: CGFloat = header ? Self.sortRoom : 0
                let measured = TextKitLayout(natural, width: nil).size
                tallest = max(tallest, measured.height)
                naturalWidths[c] = max(naturalWidths[c], min(cap, measured.width + room))
                minimumWidths[c] = max(minimumWidths[c], min(cap, longestWord(natural) + room))
                // A number stays on one line ("14.3% (9 booked)"); its header can wrap.
                if !header, c < table.numeric.count, table.numeric[c] { minimumWidths[c] = max(minimumWidths[c], min(cap, measured.width)) }
                if !header { lineWidths.append(source.length == 0 ? 0 : ceil(measured.width)) }
                let cell = TableSheetCell(header: header)
                let words = source.string
                if header {
                    cell.accessibilityTraits = [.header, .button]
                    cell.accessibilityLabel = words.isEmpty ? "Column \(c + 1)" : words
                    cell.accessibilityHint = "Sorts the rows by this column."
                    cell.onActivate = { [weak self] in self?.cycleSort(c) }
                } else {
                    let name = c < rows[0].count ? rows[0][c] : ""
                    cell.accessibilityLabel = words.isEmpty ? "Empty" : name.isEmpty ? words : "\(name), \(words)"
                }
                line.append(cell)
            }
            cells.append(line); texts.append(drawn)
            if !header { cellWidths.append(lineWidths) }
            naturalHeights.append(tallest + 2 * (header ? Self.headerPadV : Self.padV))
        }
        // Whole points, so a sheet sized to the table (the iPad's, the Mac's) holds it without a fraction to squeeze.
        naturalWidths = naturalWidths.map { ceil($0) }
        for c in 0..<columns { minimumWidths[c] = min(naturalWidths[c], max(ceil(minimumWidths[c]), 56)) }
        applyMarks()
        // [m9/ipad] A small table is not shown in an empty page: the form sheet takes the table's own size, capped.
        askForSize()
    }

    /// [m9/ipad] The table's own size for a form sheet (the iPad's, the Mac's), capped at 900 × 900: its columns at
    /// their natural widths plus whatever the page keeps at its sides, and 2 pt the Mac's scaled sheet can round away
    /// (it drew a 670 pt ask 669 wide, and the headers wrapped).
    private func askForSize() {
        guard !inPane else { return }   // [mac] the pane is the chat's: nothing to size
        let sides = scroll.adjustedContentInset.left + scroll.adjustedContentInset.right
        let natural = naturalWidths.reduce(0, +) + CGFloat(columns) * 2 * Self.padH + 2 * (Self.edge - Self.padH) + sides
        let size = CGSize(width: min(900, max(375, ceil(natural) + 2)), height: min(900, max(320, naturalHeights.reduce(0, +) + 160)))
        guard abs(size.width - preferredContentSize.width) > 0.5 || abs(size.height - preferredContentSize.height) > 0.5 else { return }
        preferredContentSize = size
        navigationController?.preferredContentSize = size
    }

    /// A reply's cell at the page's size: Subheadline for the body, Footnote semibold for the header (the reply's
    /// 13 pt cells scaled, keeping their weight, slant and monospace), wrapping, aligned in its column.
    private func restyled(_ text: NSAttributedString, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: out.length)
        guard full.length > 0 else { return out }
        let base = header ? headFont : bodyFont
        let ratio = base.pointSize / max(1, ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory).table.pointSize)
        out.removeAttribute(.baselineOffset, range: full)
        out.enumerateAttribute(.font, in: full) { value, range, _ in
            let old = value as? UIFont ?? base
            var font = old.withSize((old.pointSize * ratio).rounded())
            if !header, !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
                let d = font.fontDescriptor.addingAttributes([.featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]]])
                font = UIFont(descriptor: d, size: font.pointSize)
            }
            out.addAttribute(.font, value: font, range: range)
        }
        if header {
            out.addAttribute(.foregroundColor, value: ChatPalette.label2, range: full)
            // "Weak at follow-up" wraps before "follow-up", not after its hyphen.
            out.mutableString.replaceOccurrences(of: "-", with: "\u{2011}", options: [], range: full)
        }
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.lineBreakMode = .byWordWrapping
        p.lineHeightMultiple = 1.08
        out.addAttribute(.paragraphStyle, value: p, range: full)
        return out
    }

    private func longestWord(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? bodyFont
        return text.string.split(whereSeparator: \.isWhitespace)
            .map { ceil((String($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
    }

    // MARK: Layout

    /// Column widths for the page's width, each row as tall as its tallest cell at them, then every cell placed.
    private func layoutGrid() {
        guard columns > 0, !cells.isEmpty else { return }
        let width = available
        askForSize()   // the page's side insets are known now
        // Room around the words: 12 pt each side of a cell, 16 at the page's edges.
        let room = width - CGFloat(columns) * 2 * Self.padH - 2 * (Self.edge - Self.padH)
        let fitsAnyway = naturalWidths.reduce(0, +) <= room + 0.5
        canFit = !fitsAnyway && minimumWidths.reduce(0, +) <= room
        let squeezed = TableData.fit(natural: naturalWidths, minimum: minimumWidths, available: room)
        if !fitPicked, canFit {
            let pinnable = columns >= 2 && Self.edge + ceil(naturalWidths[0]) + Self.padH <= width * 0.45
            fitted = !(pinnable && TableData.squeezeBreaksShortCells(cellWidths, natural: naturalWidths, fitted: squeezed))
        }
        laidFor = (width, fitted)
        // [mac] In the chat's whole pane a table that fits keeps its own widths: spread over 1,400 pt its names sat a
        // hand's width from their numbers. The sheet (narrow) still shares the room.
        widths = fitsAnyway && inPane ? naturalWidths.map { ceil($0) }
            : fitsAnyway || (fitted && canFit) ? squeezed : naturalWidths.map { ceil($0) }
        xs = [0]
        for (c, w) in widths.enumerated() {
            let lead = c == 0 ? Self.edge : Self.padH, trail = c == columns - 1 ? Self.edge : Self.padH
            xs.append(xs[c] + lead + w + trail)
        }
        // The first column stays at the left when the page scrolls sideways and it leaves room for the others.
        frozen = columns >= 2 && (xs.last ?? 0) > width + 0.5 && xs[1] <= width * 0.45
        heights = []
        for (r, line) in cells.enumerated() {
            let header = r == 0
            var tallest = ceil((header ? headFont : bodyFont).lineHeight)
            for (c, cell) in line.enumerated() {
                let layout = TextKitLayout(texts[r][c], width: max(1, widths[c] - (header ? Self.sortRoom : 0)))
                // A right-aligned header's words end where its column's do: its chevron goes before them.
                cell.setText(layout, lead: header && table.alignment(c) == .right ? Self.sortRoom : 0)
                tallest = max(tallest, layout.size.height)
            }
            heights.append(tallest + 2 * (header ? Self.headerPadV : Self.padV))
        }
        headerHeight = heights[0]
        placeCells(animated: false)
        refreshMenus()
    }

    /// Puts every cell where the current order and search want it, a frozen column's in its own layer; rows that
    /// move slide there, rows that go or come fade.
    private func placeCells(animated: Bool) {
        let shown = Set(order)
        var tops: [Int: CGFloat] = [:]
        var lines: [CGFloat] = []
        var y = headerHeight
        for r in order {
            tops[r] = y
            y += heights[r + 1]
            lines.append(y)
        }
        gridSize = CGSize(width: xs.last ?? 0, height: y)
        let firstWidth = xs.count > 1 ? xs[1] : 0
        for (r, line) in cells.enumerated() {
            for (c, cell) in line.enumerated() {
                let inFrozen = frozen && c == 0
                let host: UIView = r == 0 ? (inFrozen ? cornerLayer : headerLayer) : (inFrozen ? columnLayer : bodyLayer)
                if cell.superview !== host { host.addSubview(cell) }
                let showing = r == 0 || shown.contains(r - 1)
                if showing { cell.isHidden = false }
                cell.isAccessibilityElement = showing
                if r == 0 { cell.setSort(sort?.column == c ? sort?.ascending : nil) }
            }
        }
        let move = {
            for (r, line) in self.cells.enumerated() {
                let top: CGFloat? = r == 0 ? 0 : tops[r - 1]
                for (c, cell) in line.enumerated() {
                    cell.alpha = top == nil ? 0 : 1
                    guard let top else { continue }   // a row the search hides fades where it is
                    let pad = r == 0 ? Self.headerPadV : Self.padV
                    cell.frame = CGRect(x: self.xs[c] + (c == 0 ? Self.edge : Self.padH), y: top + pad,
                                        width: self.widths[c], height: self.heights[r] - 2 * pad)
                }
            }
        }
        let settle = { self.cells.dropFirst().joined().forEach { $0.isHidden = $0.alpha < 0.5 } }
        content.frame = CGRect(origin: .zero, size: gridSize)
        bodyLayer.frame = content.bounds
        bodyLines.frame = bodyLayer.bounds
        let markedIndex = marked.flatMap { order.firstIndex(of: $0) }
        bodyLines.set(lines: lines, top: headerHeight, marked: markedIndex)
        columnLayer.isHidden = !frozen
        cornerLayer.isHidden = !frozen
        columnRule.isHidden = !frozen
        columnLines.frame = CGRect(x: 0, y: 0, width: firstWidth, height: gridSize.height)
        columnLines.set(lines: lines, top: headerHeight, marked: markedIndex)
        scroll.contentSize = gridSize
        // A table wider than the page scrolls to where its last row clears the sideways bar (owner 2026-10-29: [mac] the
        // scroller's 15 pt track sat on the 11 pt under the last row's words).
        let seen = scroll.bounds.width - scroll.adjustedContentInset.left - scroll.adjustedContentInset.right
        let lane = gridSize.width > seen + 0.5 ? max(0, ScrollBarLane.height - Self.padV) : 0
        if scroll.contentInset.bottom != lane { scroll.contentInset.bottom = lane }
        fitCard(lane: lane)
        if animated && !HQMotion.reduced {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: move) { _ in settle() }
        } else {
            move()
            settle()
        }
        stick()
        empty.isHidden = !order.isEmpty
        empty.text = order.isEmpty ? "No rows contain “\(query)”." : nil
        navigationItem.subtitle = titles.subtitle
        // VoiceOver reads the header, then the rows shown, in order.
        var reading: [TableSheetCell] = cells[0]
        for r in order { reading += cells[r + 1] }
        scroll.accessibilityElements = reading
    }

    /// Keeps the header row at the top and a frozen first column at the left as the page scrolls, each with a soft
    /// shadow once something has gone under it.
    private func stick() {
        let offset = scroll.contentOffset, inset = scroll.adjustedContentInset
        let top = max(0, offset.y + inset.top)
        let left = frozen ? max(0, offset.x + inset.left) : 0
        let firstWidth = xs.count > 1 ? xs[1] : 0
        let hairline = 1 / max(traitCollection.displayScale, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        headerLayer.frame = CGRect(x: 0, y: top, width: gridSize.width, height: headerHeight)
        cornerLayer.frame = CGRect(x: left, y: top, width: firstWidth, height: headerHeight)
        columnLayer.frame = CGRect(x: left, y: 0, width: firstWidth, height: gridSize.height)
        headerRule.frame = CGRect(x: 0, y: top + headerHeight - hairline, width: gridSize.width, height: hairline)
        columnRule.frame = CGRect(x: left + firstWidth - hairline, y: 0, width: hairline, height: gridSize.height)
        for layer in [headerLayer, cornerLayer, columnLayer] { layer.layer.shadowPath = UIBezierPath(rect: layer.bounds).cgPath }
        let down: Float = top > 0.5 ? 0.12 : 0, across: Float = left > 0.5 ? 0.12 : 0
        headerLayer.layer.shadowOpacity = down
        columnLayer.layer.shadowOpacity = across
        cornerLayer.layer.shadowOpacity = max(down, across)
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { stick() }

    // MARK: Sorting, marking, searching

    /// A header tap: ascending, then descending, then the reply's order.
    func cycleSort(_ column: Int) {
        if let sort, sort.column == column {
            self.sort = sort.ascending ? (column, false) : nil
        } else {
            sort = (column, true)
        }
        Haptics.play(.selection)
        applyOrder(animated: true)
        let name = column < rows[0].count && !rows[0][column].isEmpty ? rows[0][column] : "column \(column + 1)"
        HQAnnounce.say(sort.map { "Sorted by \(name), \($0.ascending ? "ascending" : "descending")" } ?? "Original order")
    }

    private func setSort(_ next: (column: Int, ascending: Bool)?) {
        sort = next
        Haptics.play(.selection)
        applyOrder(animated: true)
    }

    private func applyOrder(animated: Bool) {
        let body = Array(rows.dropFirst())
        var next = sort.map { TableData.order(body, column: $0.column, ascending: $0.ascending) } ?? Array(body.indices)
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            next = next.filter { r in body[r].contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        }
        order = next
        applyMarks()
        if !widths.isEmpty { placeCells(animated: animated) }
        refreshMenus()
    }

    /// The search's matches, marked in the cells.
    private func applyMarks() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        for (r, line) in cells.enumerated() {
            for (c, cell) in line.enumerated() {
                cell.marks = needle.isEmpty ? [] : InlineCodeText.findRanges(of: needle, in: texts[r][c].string)
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        applyOrder(animated: false)
    }

    @objc private func tapped(_ gr: UITapGestureRecognizer) {
        guard let (r, c, cell) = cell(at: gr.location(in: scroll)) else {
            mark(nil)
            return
        }
        if r == 0 { cycleSort(c); return }
        if let url = cell.link(at: gr.location(in: cell)) {
            LinkOpener.open(url, from: self)
            return
        }
        mark(marked == r - 1 ? nil : r - 1)
    }

    /// Marks a body row (nil clears it), to follow it across the table.
    private func mark(_ row: Int?) {
        guard row != marked else { return }
        marked = row
        if row != nil { Haptics.play(.selection) }
        let index = marked.flatMap { order.firstIndex(of: $0) }
        bodyLines.marked = index
        columnLines.marked = index
        for (r, line) in cells.enumerated() where r > 0 {
            for cell in line { cell.accessibilityTraits = marked == r - 1 ? .selected : .none }
        }
    }

    /// The cell under a point in the scroll view's coordinates (the frozen corner, header and column first): its row
    /// (0 = header), column and view.
    private func cell(at point: CGPoint) -> (Int, Int, TableSheetCell)? {
        for host in [cornerLayer, headerLayer, columnLayer, bodyLayer] where !host.isHidden {
            let p = scroll.convert(point, to: host)
            guard host.bounds.contains(p) else { continue }
            for (r, line) in cells.enumerated() {
                for (c, cell) in line.enumerated() where cell.superview === host && !cell.isHidden {
                    let pad = r == 0 ? Self.headerPadV : Self.padV
                    let lead = c == 0 ? Self.edge : Self.padH, trail = c == columns - 1 ? Self.edge : Self.padH
                    let area = CGRect(x: cell.frame.minX - lead, y: cell.frame.minY - pad,
                                      width: cell.frame.width + lead + trail, height: heights[r])
                    if area.contains(p) { return (r, c, cell) }
                }
            }
            return nil
        }
        return nil
    }

    // MARK: Menus

    private func refreshMenus() {
        guard isViewLoaded else { return }
        var viewing: [UIMenuElement] = []
        if canFit {
            viewing.append(UIAction(title: "Fit to Screen", image: UIImage(systemName: "arrow.left.and.right.square"),
                                    state: fitted ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.setFitted(!self.fitted)
            })
        }
        var sorting: [UIMenuElement] = []
        if sort != nil {
            sorting.append(UIAction(title: "Original Order", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.setSort(nil)
            })
        }
        let sortBy = (0..<columns).map { c -> UIAction in
            let name = c < rows[0].count && !rows[0][c].isEmpty ? rows[0][c] : "Column \(c + 1)"
            let on = sort?.column == c
            let glyph = on ? UIImage(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down") : nil
            return UIAction(title: name, image: glyph, state: on ? .on : .off) { [weak self] _ in self?.cycleSort(c) }
        }
        sorting.append(UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: sortBy))
        moreItem.menu = UIMenu(children: [UIMenu(options: .displayInline, children: viewing),
                                          UIMenu(options: .displayInline, children: sorting)])
        shareItem.menu = UIMenu(children: [
            UIAction(title: "Copy as Markdown", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in self?.copyMarkdown() },
            UIAction(title: "Copy as CSV", image: UIImage(systemName: "tablecells")) { [weak self] _ in self?.copyCSV() },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Share CSV File…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareCSV() },
            ]),
        ] + (fileShare.isEmpty ? [] : [UIMenu(options: .displayInline, children: fileShare)]))
    }

    func setFitted(_ on: Bool) {
        fitted = on
        fitPicked = true
        scroll.contentOffset = CGPoint(x: -scroll.adjustedContentInset.left, y: scroll.contentOffset.y)
        if HQMotion.reduced {
            layoutGrid()
        } else {
            UIView.transition(with: content, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.layoutGrid()
            }
        }
    }

    /// The rows as shown (sorted and searched), header first: what the share menu copies.
    var shownRows: [[String]] { [rows[0]] + order.map { rows[$0 + 1] } }

    private func copyMarkdown() {
        let aligns = (0..<columns).map { c -> TableData.Alignment in
            switch c < table.alignments.count ? table.alignments[c] : .natural {
            case .right: return .right
            case .center: return .center
            default: return .natural
            }
        }
        copied(TableData.markdown(shownRows, alignments: aligns), saying: "Copied as Markdown")
    }

    private func copyCSV() { copied(TableData.csv(shownRows), saying: "Copied as CSV") }

    private func copied(_ text: String, saying words: String) {
        UIPasteboard.general.string = text
        Haptics.play(.success)
        HQAnnounce.say(words)
        flashCopied()
    }

    private func shareCSV() {
        let name = titles.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((name.isEmpty ? "Table" : name) + ".csv")
        do {
            try TableData.csv(shownRows).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Haptics.play(.error)
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = shareItem
        present(sheet, animated: true)
    }

    // MARK: Hold menu on a cell

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let (r, c, cell) = cell(at: location) else { return nil }
        let link = r > 0 ? cell.link(at: scroll.convert(location, to: cell)) : nil
        return UIContextMenuConfiguration(identifier: "\(r),\(c)" as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let word = c < self.rows[r].count ? self.rows[r][c] : ""
            let column = self.shownRows.map { c < $0.count ? TableText.cell($0[c]) : "" }
            var items: [UIMenuElement] = []
            if let link {
                items.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { [weak self] _ in
                    guard let self else { return }
                    LinkOpener.open(link, from: self)
                })
            }
            if r == 0 {
                items.append(UIAction(title: "Sort Ascending", image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                    self?.setSort((c, true))
                })
                items.append(UIAction(title: "Sort Descending", image: UIImage(systemName: "chevron.down")) { [weak self] _ in
                    self?.setSort((c, false))
                })
            } else if !word.isEmpty {
                let short = word.count > 24 ? String(word.prefix(23)) + "…" : word
                items.append(UIAction(title: "Copy “\(short)”", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copied(TableText.cell(word), saying: "Copied")
                })
                items.append(UIAction(title: "Copy Row", image: UIImage(systemName: "arrow.left.and.right.text.vertical")) { [weak self] _ in
                    guard let self else { return }
                    self.copied(TableText.text([self.rows[r]]), saying: "Copied the row")
                })
            }
            items.append(UIAction(title: "Copy Column", image: UIImage(systemName: "arrow.up.and.down.text.horizontal")) { [weak self] _ in
                self?.copied(column.joined(separator: "\n"), saying: "Copied the column")
            })
            return UIMenu(children: items)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: identifier)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: identifier)
    }

    /// The held cell lifts on its own, on a rounded patch of the page's colour.
    private func preview(for identifier: any NSCopying) -> UITargetedPreview? {
        guard let key = identifier as? NSString else { return nil }
        let parts = (key as String).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] < cells.count, parts[1] < cells[parts[0]].count else { return nil }
        let cell = cells[parts[0]][parts[1]]
        guard cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = ChatPalette.page
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: -8, dy: -6), cornerRadius: 8)
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    // MARK: Copy as Text

    @objc private func copyTapped() {
        guard let text = TableText.copyable(rows) else {
            failure.isHidden = false
            Haptics.play(.error)
            HQAnnounce.say(TableText.failure, priority: .high)
            return
        }
        UIPasteboard.general.string = text
        Haptics.play(.success)
        HQAnnounce.say(Self.copiedTitle)
        flashCopied()
    }

    private func flashCopied() {
        copyItem.title = Self.copiedTitle
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyItem.title = Self.copyTitle }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// One cell of the Table page: its words (drawn like a reply's, so links and search marks work) and, on a header, the
/// sort chevron after them.
final class TableSheetCell: UIView {
    private let text = TextDrawView()
    private let chevron = UIImageView()
    private let header: Bool
    private var lastLineEnd: CGFloat = 0
    var onActivate: (() -> Void)?
    var marks: [NSRange] = [] {
        didSet { if marks != oldValue { text.findHighlights = marks.map { TextDrawView.FindMark(range: $0, current: false) } } }
    }

    init(header: Bool) {
        self.header = header
        super.init(frame: .zero)
        isUserInteractionEnabled = false   // the page's own tap and hold find the cell
        isAccessibilityElement = true
        addSubview(text)
        if header {
            chevron.tintColor = ChatPalette.tintText
            chevron.contentMode = .center
            chevron.isHidden = true
            addSubview(chevron)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The words, `lead` points in (a right-aligned header's room for its chevron).
    func setText(_ layout: TextKitLayout, lead: CGFloat = 0) {
        text.set(layout: layout)
        text.frame = CGRect(x: lead, y: 0, width: layout.container.size.width, height: layout.size.height)
        lastLineEnd = layout.lastLineMaxX
        firstLineStart = 0
        let glyphs = layout.manager.numberOfGlyphs
        if glyphs > 0 { firstLineStart = layout.manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).minX }
        setNeedsLayout()
    }

    private var firstLineStart: CGFloat = 0

    private var font: UIFont? {
        guard let t = text.textKit?.text, t.length > 0 else { return nil }
        return t.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    }

    /// The header's chevron: up for ascending, down for descending, none when the rows aren't sorted by it.
    func setSort(_ ascending: Bool?) {
        guard header else { return }
        chevron.isHidden = ascending == nil
        accessibilityValue = ascending.map { $0 ? "Sorted ascending" : "Sorted descending" }
        guard let ascending else { return }
        chevron.image = UIImage(systemName: ascending ? "chevron.up" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: ((font?.pointSize ?? 13) * 0.75).rounded(), weight: .bold))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard header, let image = chevron.image else { return }
        let lineHeight = font?.lineHeight ?? 16
        // After the words; before them when they are pushed in (right-aligned).
        let x = text.frame.minX > 0 ? text.frame.minX + firstLineStart - 4 - image.size.width
                                    : min(lastLineEnd + 4, bounds.width - image.size.width)
        chevron.frame = CGRect(x: max(0, x), y: (lineHeight - image.size.height) / 2,
                               width: image.size.width, height: image.size.height).integral
    }

    func link(at point: CGPoint) -> URL? { text.link(at: convert(point, to: text)) }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// The Table page's row lines and the marked row, drawn under the cells.
final class TableSheetRowsView: UIView {
    private var lines: [CGFloat] = []
    private var top: CGFloat = 0
    /// The marked row's place among those shown.
    var marked: Int? { didSet { if marked != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TableSheetRowsView, _) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `lines`: each shown row's bottom edge, in order; `top`: where the first starts (under the header).
    func set(lines: [CGFloat], top: CGFloat, marked: Int?) {
        self.lines = lines
        self.top = top
        self.marked = marked
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let marked, marked < lines.count {
            let start = marked == 0 ? top : lines[marked - 1]
            ChatPalette.tint.resolvedColor(with: traitCollection).withAlphaComponent(0.14).setFill()
            ctx.fill(CGRect(x: 0, y: start, width: bounds.width, height: lines[marked] - start))
        }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        ChatPalette.separator.resolvedColor(with: traitCollection).setFill()
        for y in lines.dropLast() {
            ctx.fill(CGRect(x: 0, y: y - hairline / 2, width: bounds.width, height: hairline))
        }
    }
}
