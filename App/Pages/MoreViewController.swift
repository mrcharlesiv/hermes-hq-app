// The More tab's root (docs/spec/1x-pages.md §1.2): grouped rows, each a 29 pt rounded-square icon tile, a Body title
// and a chevron; a row pushes its page on More's own stack (the tab bar stays). Only rows that work are listed; other
// streams add theirs with `PagesTabs.registerMoreSection`.

import UIKit

final class MoreViewController: UIViewController, UICollectionViewDelegate {
    private let sections: () -> [MoreSection]
    private var current: [(section: MoreSection, rows: [MoreRow])] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    /// [morepages] More search behind the bar's magnifier (docs/spec/3x-morepages.md §18): App/Pages/More/MoreSearchUI.swift.
    private var searchUI: MoreSearchUI?
    /// ⌘F on More, and ⌘K (Open Quickly) from anywhere: the bar's search opened with the caret in it.
    func openSearchFromKeyboard() { searchUI?.capsule?.openSearch() }
    /// [mac] Open Quickly's finder and opener (`MacOpenQuickly`): More's own search, so a result opens as it does here.
    var quickSearch: MoreSearchUI? { searchUI }

    init(sections: @escaping () -> [MoreSection]) {
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
        PageChrome.applyListHeader(to: self, title: "More")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.backgroundColor = HQPalette.groupedPage   // [desktoplook] the list paints its own page: it follows the skin
        // [compact] iOS's own list, with the section gaps closer (as the SwiftUI pages' compact section spacing).
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if !Theme.isDesktop {
                section.contentInsets.top = min(section.contentInsets.top, MoreMetrics.sectionGap / 2)
                section.contentInsets.bottom = min(section.contentInsets.bottom, MoreMetrics.sectionGap / 2)
            }
            // Owner 2026-11-09: the website and GitHub buttons under the last group.
            if let self, index == self.current.count - 1 {
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60))
                section.boundarySupplementaryItems.append(NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: size, elementKind: MoreLinksFooter.kind, alignment: .bottom))
            }
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "more.list"
        collectionView.backgroundColor = HQPalette.groupedPage   // [desktoplook] the page follows the skin
        view.addSubview(collectionView)
        ListBarAppearance.pinTitle(in: self, grouped: true, softEdgeAround: collectionView)   // owner 2026-11-01: every tab's top
        PageBackdrop.install(in: self, clearing: [collectionView])   // [backdrop] Theme › App Background
        #if targetEnvironment(macCatalyst)
        typealias RowCell = MacCardCell   // [mac] Stress test 2026-10-28 round 8: keeps the Desktop Look's card corners
        #else
        typealias RowCell = UICollectionViewListCell
        #endif
        let cell = UICollectionView.CellRegistration<RowCell, String> { [weak self] cell, _, id in
            guard let row = self?.row(id) else { return }
            // [desktoplook2] flat rows in an outlined box, the press as the desktop's inset box
            if Theme.isDesktop {
                cell.configurationUpdateHandler = { cell, state in cell.backgroundConfiguration = DesktopLayout.rowBackground(state) }
            } else if cell.configurationUpdateHandler != nil {
                cell.configurationUpdateHandler = nil
                cell.backgroundConfiguration = cell.defaultBackgroundConfiguration()
            }
            #if targetEnvironment(macCatalyst)
            // [mac] Stress test 2026-10-28 #54: the window's one source-list mark, a box inside the row in both looks.
            cell.configurationUpdateHandler = { cell, state in
                cell.backgroundConfiguration = MacSelection.groupedRow(cell, state)   // [mac] #54 (round 6): to the card's shape in both looks
            }
            #endif
            if let card = row.card {
                cell.contentConfiguration = card()
                cell.accessories = []
                cell.accessibilityIdentifier = "more-row-\(row.id)"
                return
            }
            // [capabilities] a row with a status is a value cell: the value sits before the chevron, red for an issue,
            // and wraps under the title at accessibility sizes (the system's own stacked layout).
            let status = row.status?()
            var content = status == nil ? UIListContentConfiguration.cell().hqScaled() : UIListContentConfiguration.valueCell().hqScaled()
            content.text = row.title
            // [ui-sizing 2026-11-09] × UI Scale on the iPhone too, as the Mac's: the rows grew and the tiles stayed 29 pt.
            let side = HQFont.scaled(29)
            content.image = Self.tile(row, side: side)
            content.imageProperties.maximumSize = CGSize(width: side, height: side)
            content.imageToTextPadding = 14
            content.directionalLayoutMargins.top = MoreMetrics.rowPad      // [compact] as tall as a Settings row
            content.directionalLayoutMargins.bottom = MoreMetrics.rowPad
            if Theme.isDesktop {   // [desktoplook2] the desktop's small monochrome glyph, no coloured tile (css:157-162)
                content.image = Self.glyph(row)
                content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
                content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
                content.imageProperties.tintColor = HQPalette.label2
                content.imageToTextPadding = 12
                content.textProperties.font = HQFont.preferred(.callout)
            }
            if DeviceWord.isMac {
                // [mac] Stress test 2026-10-28 #58: one glyph size and weight (`MacIcon.row`, the row text's size) in a
                // fixed column, so Changes and Spawn Tree aren't shrunk thin and Kanban and Bot Profiles aren't bigger;
                // the iOS look's tiles grow with the text as the rows do.
                let column = Theme.isDesktop ? MacIcon.rowColumn : HQFont.scaled(29)
                if Theme.isDesktop { content.image = Self.macGlyph(row) }
                else { content.image = Self.tile(row, side: column) }
                content.imageProperties.maximumSize = CGSize(width: column, height: column)
                content.imageProperties.reservedLayoutSize = CGSize(width: column, height: column)
            }
            if let status {
                content.secondaryText = status.text
                content.secondaryTextProperties.color = status.isIssue ? .systemRed : HQPalette.label2
                content.secondaryTextProperties.numberOfLines = 0
                // [mac-audit] Owner 2026-11-02 (#21): the value at the row's own size; in the Desktop Look the rows are
                // callout and "Update Hermes" stood larger than the name beside it.
                if Theme.isDesktop { content.secondaryTextProperties.font = content.textProperties.font }
            }
            if row.dimmed {
                // [mac-audit] Owner 2026-11-02 (#21): a page this Hermes doesn't have reads as greyed out, its
                // "Update Hermes" as quiet as its title; the row still opens the page, which says why.
                content.textProperties.color = HQPalette.label3
                content.secondaryTextProperties.color = HQPalette.label3
                content.imageProperties.tintColor = HQPalette.label3
                if let image = content.image, image.renderingMode != .alwaysTemplate, !image.isSymbolImage {
                    content.image = UIGraphicsImageRenderer(size: image.size).image { _ in
                        image.draw(at: .zero, blendMode: .normal, alpha: 0.4)
                    }
                }
            }
            cell.contentConfiguration = content
            // [mac] Stress test 2026-10-28 #51: More is a source list on the Mac, its rows have no › chevron.
            cell.accessories = DeviceWord.isMac ? [] : [.disclosureIndicator()]
            let badge = row.badge?().flatMap { $0.count > 0 ? $0 : nil }
            if let badge {   // [addon-reminder] the red count, before the chevron
                cell.accessories.insert(.customView(configuration: .init(customView: CountBadge.view(badge.count), placement: .trailing(),
                                                                         reservedLayoutWidth: .actual)), at: 0)
            }
            cell.accessibilityIdentifier = "more-row-\(row.id)"
            cell.accessibilityLabel = status.map { "\(row.title), \($0.spoken)" } ?? badge.map { "\(row.title), \($0.spoken)" }
            cell.accessibilityValue = status?.text
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            var content = UIListContentConfiguration.header().hqScaled()
            content.text = self.flatMap { path.section < $0.current.count ? $0.current[path.section].section.header : nil }
            if Theme.isDesktop, let text = content.text {   // [desktoplook2] the desktop's label
                content.attributedText = NSAttributedString(string: text.uppercased(), attributes: DesktopLayout.labelAttributes())
            }
            header.contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { cv, path, id in
            cv.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        let links = UICollectionView.SupplementaryRegistration<MoreLinksFooter>(elementKind: MoreLinksFooter.kind) { footer, _, _ in
            footer.update()
        }
        dataSource.supplementaryViewProvider = { cv, kind, path in
            kind == MoreLinksFooter.kind ? cv.dequeueConfiguredReusableSupplementary(using: links, for: path)
                : cv.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
        // [capabilities] issue counts change while More is on screen: reconfigure in place (no scroll jump).
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {                       // [desktoplook2] rows, glyphs and the outline follow the look
                guard let self else { return }
                self.reload()
                DesktopListOutliner.attach(to: self.collectionView)
                #if targetEnvironment(macCatalyst)
                self.updateEdgeLine()   // [mac] Stress test 2026-10-28 round 6
                #endif
            }
        }
        NotificationCenter.default.addObserver(forName: ServerIssues.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: AddOnReminder.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }   // [addon-reminder] Settings' badge
        }
        reload()
        searchUI = MoreSearchUI(host: self, sections: sections)   // [morepages] §18
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 round 6: in the iOS look the list's bar is opaque with no hairline in any state
        // (#57), so at laptop width the gateway card slid under it and looked cut off. A hairline shows under the bar
        // while rows are under it; the Desktop Look's frost bar shows them through and keeps none.
        edgeLine.backgroundColor = HQPalette.separator
        edgeLine.isUserInteractionEnabled = false
        edgeLine.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edgeLine)
        NSLayoutConstraint.activate([
            edgeLine.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            edgeLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edgeLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edgeLine.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
        updateEdgeLine()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 round 6: the iOS look's scroll-edge hairline under More's bar (see viewDidLoad).
    private let edgeLine = UIView()

    private func updateEdgeLine() {
        guard collectionView != nil else { return }
        let under = collectionView.contentOffset.y + collectionView.adjustedContentInset.top > 0.5
        edgeLine.isHidden = Theme.isDesktop || !under
        edgeLine.backgroundColor = HQPalette.separator
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateEdgeLine() }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchUI?.restore()   // [morepages] a typed query comes back with its results
        reload()
        DesktopListOutliner.attach(to: collectionView)      // [desktoplook2] only while the look is on
        #if targetEnvironment(macCatalyst)
        MacCardRounder.attach(to: collectionView)           // [mac-ui-issues] the iOS look's cards as Mac group boxes
        #endif
        if !paneKeepsSelection, let selected = collectionView.indexPathsForSelectedItems?.first {
            transitionCoordinator?.animate(alongsideTransition: { _ in self.collectionView.deselectItem(at: selected, animated: true) })
            if transitionCoordinator == nil { collectionView.deselectItem(at: selected, animated: animated) }
        }
    }

    #if DEBUG
    /// `-HQDebugScrollMoreEnd YES`: More opens scrolled to its foot (screenshots of the website and GitHub buttons).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard UserDefaults.standard.bool(forKey: "HQDebugScrollMoreEnd") else { return }
        for delay in [1.0, 1.5, 2.0] {   // again once the footer has sized itself
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let cv = self?.collectionView else { return }
                cv.layoutIfNeeded()
                let bottom = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                cv.setContentOffset(CGPoint(x: 0, y: max(-cv.adjustedContentInset.top, bottom)), animated: false)
            }
        }
    }
    #endif

    func reload() {
        guard isViewLoaded else { return }
        current = sections().map { ($0, $0.rows()) }.filter { !$0.rows.isEmpty }
        #if targetEnvironment(macCatalyst)
        // [mac-ui-issues] Owner 2026-11-09 ("really refine the app"): no Settings row on the Mac. It only opened the
        // Settings window, which the sidebar's gear, the app menu and ⌘, already do; the gear carries the row's red dot
        // (`MacSidebar.showSettingsDot`). Search and ⌘K still find Settings: they read the sections, not this list.
        current = current.map { ($0.section, $0.rows.filter { $0.id != PagesTabs.settingsRowID }) }.filter { !$0.rows.isEmpty }
        #endif
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for (section, rows) in current {
            snapshot.appendSections([section.id])
            snapshot.appendItems(rows.map { section.id + "/" + $0.id }, toSection: section.id)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        if paneKeepsSelection { markOnShow(onShow, keepsSelection: true) }   // [m9/ipad]
    }

    private func row(_ id: String) -> MoreRow? {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return current.first { $0.section.id == parts[0] }?.rows.first { $0.id == parts[1] }
    }

    /// A 29 pt rounded square in the row's colour with its white glyph.
    static func tile(_ row: MoreRow, side: CGFloat = 29) -> UIImage {
        let glyphSide = 19 * side / 29
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            row.tile.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 7 * side / 29).fill()
            let glyph = row.image ?? row.symbol.flatMap {
                UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15 * side / 29, weight: .semibold))
            }
            guard let glyph else { return }
            let tinted = glyph.withTintColor(.white, renderingMode: .alwaysOriginal)
            let fit = min(glyphSide / max(tinted.size.width, 1), glyphSide / max(tinted.size.height, 1), 1)
            let size = CGSize(width: tinted.size.width * fit, height: tinted.size.height * fit)
            tinted.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }

    /// [mac] Stress test 2026-10-28 #58 (round 2): at one size and weight, Changes' branch and Spawn Tree's dotted nodes
    /// are hairline drawings next to the other glyphs' solid shapes. Those two are drawn heavier (Spawn Tree with its
    /// nodes filled) so the column reads as one weight.
    /// [mac] Stress test 2026-10-28 round 6: every glyph an outline. Bot Profiles' person.crop.circle (a solid figure in
    /// a ring), Spawn Tree's filled nodes and Star Map's solid sparkles read as filled beside the others; they take
    /// outline symbols (person, the open nodes drawn heavier, star).
    static func macGlyph(_ row: MoreRow) -> UIImage? {
        func outline(_ name: String, weight: UIImage.SymbolWeight? = nil) -> UIImage? {
            let config = weight.map { MacIcon.row.applying(UIImage.SymbolConfiguration(weight: $0)) } ?? MacIcon.row
            return UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
                ?? glyph(row, configuration: MacIcon.row)
        }
        // [mac] Stress test 2026-10-28 round 7: Kanban's drawn board is a 28 pt picture with a 1.9/24 stroke, scaled into
        // the column: about 0.115 of the text size against an SF outline's ~0.075, so it read heavier than its
        // neighbours in the Desktop Look. Drawn at the column's size with the symbols' stroke.
        if row.id == "kanban" { return kanbanGlyph() }
        switch row.symbol {
        case "person.crop.circle":
            return outline("person")
        case "sparkles":
            return outline("star")
        case "point.3.connected.trianglepath.dotted":
            return outline("point.3.connected.trianglepath.dotted", weight: .semibold)
        case "arrow.triangle.branch":
            return glyph(row, configuration: MacIcon.row.applying(UIImage.SymbolConfiguration(weight: .semibold)))
        default:
            return glyph(row, configuration: MacIcon.row)
        }
    }

    /// [mac] Round 7: lucide `square-kanban` at the size it drew at, stroked as an SF outline at the row's size is.
    private static func kanbanGlyph() -> UIImage {
        let side = min(28, MacIcon.rowColumn)   // the size it drew at before, only the stroke changes
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            let unit = side / 24
            ctx.scaleBy(x: unit, y: unit)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 18, height: 18), cornerWidth: 2, cornerHeight: 2, transform: nil))
            for d in ["M8 7v7", "M12 7v4", "M16 7v9"] { ctx.addPath(SVGPathData.path(d)) }
            ctx.setLineWidth(MacIcon.rowSize * 0.075 / unit)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// [desktoplook2] The row's glyph alone, as a template the cell tints. A symbol filled for its white-on-tile look
    /// takes its outline form when there is one, so every glyph has the sidebar's one weight (UX study #197).
    static func glyph(_ row: MoreRow, configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        if let image = row.image { return image.withRenderingMode(.alwaysTemplate) }
        let config = configuration ?? UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return row.symbol.flatMap { symbol in
            if symbol.hasSuffix(".fill"), let outline = UIImage(systemName: String(symbol.dropLast(".fill".count)), withConfiguration: config) {
                return outline
            }
            return UIImage(systemName: symbol, withConfiguration: config)
        }
    }

    /// Opens a row by its id (launch hooks, tests).
    func open(rowId: String) {
        guard let section = current.first(where: { $0.rows.contains { $0.id == rowId } }),
              let page = section.rows.first(where: { $0.id == rowId })?.make() else { return }
        opened = (section.section.id + "/" + rowId, Weak(page: page))
        navigationController?.pushViewController(page, animated: true)
    }

    #if targetEnvironment(macCatalyst)
    /// [mac-sidebar] A row's Control-click: Add to Sidebar, for a page the Mac's sidebar can list (owner 2026-10-31).
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), let row = row(id), row.card == nil,
              let menu = SidebarEditing.moreRowMenu(rowID: row.id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    #endif

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(id), let page = row.make() else {
            collectionView.deselectItem(at: indexPath, animated: true)
            return
        }
        opened = (id, Weak(page: page))
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: [m9/ipad] Two panes (App/Root/PaneRouter.swift)

    /// Two panes: the row of the page on show stays marked while the list shows, as on Bots and Sessions.
    private var paneKeepsSelection = false
    /// The page the right pane shows, when More opened it (kept so the mark comes back after the list reloads).
    private weak var onShow: UIViewController?
    /// The last page a row opened, with that row's item.
    private var opened: (item: String, page: Weak)?
    private struct Weak { weak var page: UIViewController? }

    /// Marks the row whose page is `page` (the right pane's root); nil, or a page More did not open, clears it.
    func markOnShow(_ page: UIViewController?, keepsSelection: Bool) {
        paneKeepsSelection = keepsSelection
        onShow = keepsSelection ? page : nil
        guard isViewLoaded, dataSource != nil else { return }
        let item = opened.flatMap { opened in page != nil && opened.page.page === page ? opened.item : nil }
        let path = item.flatMap { dataSource.indexPath(for: $0) }
        for selected in collectionView.indexPathsForSelectedItems ?? [] where selected != path {
            collectionView.deselectItem(at: selected, animated: false)
        }
        if let path { collectionView.selectItem(at: path, animated: false, scrollPosition: []) }
        if DeviceWord.isMac, let path { revealOnMac(path) }
        if DeviceWord.isMac, path == nil { unrevealOnMac() }
    }

    /// [mac] Stress test 2026-10-28 round 7: where the list was before `revealOnMac` scrolled it, and where that left it.
    /// Opening a row near the foot (Webhooks, Import Sessions) scrolled the list to show it, and closing that page left
    /// it scrolled: the list came back later (at laptop width) with the server card half under the bar.
    private var beforeReveal: CGPoint?
    private var afterReveal: CGPoint?

    /// [mac] Round 7: with no page of More's on show, a list only the reveal scrolled goes back where it was. A list the
    /// person scrolled since keeps their place.
    private func unrevealOnMac() {
        defer { beforeReveal = nil; afterReveal = nil }
        guard let before = beforeReveal, let after = afterReveal, abs(collectionView.contentOffset.y - after.y) < 0.5 else { return }
        collectionView.setContentOffset(before, animated: false)
    }

    /// [mac] Stress test 2026-10-28 #68: in a short window the list runs past the window's foot, and a page opened from
    /// a row down there (Import Sessions) left its marked row cut in half. The list scrolls just enough to show it.
    private func revealOnMac(_ path: IndexPath) {
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        let insets = collectionView.adjustedContentInset
        let visible = collectionView.bounds.inset(by: UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        guard !visible.contains(frame) else { return }
        // [mac] Round 7: kept, so closing the page puts the list back (`unrevealOnMac`).
        let start = collectionView.contentOffset
        if afterReveal.map({ abs($0.y - start.y) >= 0.5 }) ?? true { beforeReveal = start }
        collectionView.scrollRectToVisible(frame.insetBy(dx: 0, dy: -12), animated: false)
        afterReveal = collectionView.contentOffset
    }
}

/// Owner 2026-11-09: two small buttons at the foot of More, to the website and the open-source repo on GitHub. A
/// footer, not rows: they open Safari, so they aren't pages for search, the tab bar or the Mac's sidebar.
final class MoreLinksFooter: UICollectionReusableView {
    static let kind = "more.links"
    static let website = URL(string: "https://gethermeshq.com")!
    static let github = URL(string: "https://github.com/mrcharlesiv/hermes-hq-app")!

    private let stack = UIStackView()
    private let websiteButton = UIButton(type: .system)
    private let githubButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
        ])
        for (button, title, symbol, url, id) in [
            (websiteButton, "Website", "globe", Self.website, "more.link.website"),
            (githubButton, "GitHub", "chevron.left.forwardslash.chevron.right", Self.github, "more.link.github"),
        ] {
            button.accessibilityIdentifier = id
            button.accessibilityLabel = title
            button.accessibilityHint = "Opens \(url.host() ?? "") in your browser"
            button.addAction(UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
                UIApplication.shared.open(url)
            }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Styled for the look on show (re-run when the list reloads after a theme change).
    func update() {
        for button in [websiteButton, githubButton] {
            let title = button === websiteButton ? "Website" : "GitHub"
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .capsule
            config.imagePadding = 6
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.image = UIImage(systemName: button === websiteButton ? "globe" : "chevron.left.forwardslash.chevron.right",
                                   withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small))
            var text = AttributedString(title)
            let font = HQFont.preferred(.footnote)
            text.font = HQFont.system(ofSize: font.pointSize, weight: .medium)
            config.attributedTitle = text
            config.baseForegroundColor = HQPalette.label2
            button.configuration = config
        }
    }
}

/// [compact] The More list's spacing in the iOS look (owner 2026-10-17: things too tall).
enum MoreMetrics {
    static let sectionGap: CGFloat = 20
    static let rowPad: CGFloat = 8
}
