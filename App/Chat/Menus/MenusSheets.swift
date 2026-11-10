import UIKit

// Shared pieces of the menus stream's sheets (spec 1x §6, §7.3): the picker sheet frame (page sheet, medium → large on
// search, grabber, leading Cancel, a glass page with solid rows), skeleton rows, footnote section headers, and the "Copied" HUD.

enum MenusSheet {
    /// A picker sheet: a pick closes it, so Cancel leads and there is no Done (S:ui-chat/model-sheet.tsx:125).
    /// [mac] Stress test 2026-10-28 #55: `closeWord` .done for a sheet that is a list to browse (Commands): nothing in it
    /// is thrown away by closing, so the Mac says Done, not Cancel. The iPhone keeps the system's item.
    static func wrap(_ root: UIViewController, title: String, closeWord: UIBarButtonItem.SystemItem = .cancel) -> UINavigationController {
        root.title = title
        let cancel = UIBarButtonItem.hqClose(DeviceWord.isMac ? closeWord : .cancel, action: UIAction { [weak root] _ in
            guard let root else { return }
            MenusSheet.close(root) {}
        })
        cancel.accessibilityIdentifier = "sheet.cancel"
        // [mac] Stress test 2026-10-28 #55: a lone Done (Commands) sits trailing on the Mac; a picker's Cancel leads.
        if DeviceWord.isMac && closeWord != .cancel { root.navigationItem.hqPlaceClose(cancel) } else { root.navigationItem.leftBarButtonItem = cancel }
        root.navigationItem.largeTitleDisplayMode = .never
        let navigation = UINavigationController(rootViewController: root)
        SheetStyle.apply(navigation, from: nil)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.selectedDetentIdentifier = .medium
            // No grabber, as every other sheet (ChatSheet.wrap; verify round 1 found the two kinds side by side).
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            // [glass] On Liquid Glass at half height, rows on solid cards (the bubbles never tint a value); opaque at
            // full height and in the Desktop Look.
            sheet.hqGlassPage()
        }
        return navigation
    }

    /// The search field under the bar: stacked, never hidden, focusing it opens the sheet to large.
    static func searchController(placeholder: String, autocorrect: Bool, delegate: UISearchBarDelegate & UISearchResultsUpdating)
        -> UISearchController {
        #if targetEnvironment(macCatalyst)
        let search: UISearchController = MacCardAlignedSearch(searchResultsController: nil)   // [mac] Stress test 2026-10-28 #53
        #else
        let search = UISearchController(searchResultsController: nil)
        #endif
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchResultsUpdater = delegate
        search.searchBar.delegate = delegate
        search.searchBar.placeholder = placeholder
        search.searchBar.autocapitalizationType = .none
        if !autocorrect { search.searchBar.autocorrectionType = .no; search.searchBar.spellCheckingType = .no }
        search.searchBar.searchTextField.accessibilityIdentifier = "sheet.search"
        search.searchBar.hqSolidOnGlass()   // [glass-design] solid like the cards while the sheet sits on glass
        return search
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #53: the sheets' search field (Commands, Models, Model Prices) started 4 pt left of the
    /// cards under it, and ended 4 pt right of them. Its field is drawn 4 pt in at each end, so its edges are the cards'.
    private final class MacCardAlignedSearch: UISearchController {
        private let bar = CardAlignedBar()
        override var searchBar: UISearchBar { bar }
    }

    private final class CardAlignedBar: UISearchBar {
        static let inset: CGFloat = 4
        override func layoutSubviews() {
            super.layoutSubviews()
            let field = searchTextField
            guard field.frame.width > 4 * Self.inset else { return }
            // From the field's own place each pass (the bar lays it out again), never compounding.
            var frame = field.frame
            if let laid = laidOut, abs(laid.minX - frame.minX) < 0.5, abs(laid.width - frame.width) < 0.5 { return }
            frame = frame.insetBy(dx: Self.inset, dy: 0)
            field.frame = frame
            laidOut = frame
        }
        private var laidOut: CGRect?
    }
    #endif

    /// Opens the sheet to its large detent (Reduce Motion: without animation).
    static func expand(_ controller: UIViewController) {
        guard let sheet = controller.navigationController?.sheetPresentationController, sheet.selectedDetentIdentifier != .large else { return }
        if HQMotion.reduced {
            sheet.selectedDetentIdentifier = .large
        } else {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }

    /// Closes the whole sheet `controller` sits in, then runs `done`. Not `controller.dismiss`: with its search field
    /// active, that only ends the search (the search controller is what it presents).
    static func close(_ controller: UIViewController, then done: @escaping () -> Void) {
        let sheet = controller.navigationController ?? controller
        guard let presenter = sheet.presentingViewController else { done(); return }
        presenter.dismiss(animated: true, completion: done)
    }

    /// The topmost controller above `base` that isn't on its way out (alerts go there).
    static func top(_ base: UIViewController?) -> UIViewController? {
        var top = base
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

extension UITableView {
    /// After the rows above it changed (a star added or took away Favorites), scrolls so the row at `path` is back at
    /// `before` (its top on screen, window coordinates). Estimated heights settle as rows lay out: measure the row as
    /// drawn, move, and measure again (≤ 3 passes).
    func hqHoldRow(at path: IndexPath, onScreenAt before: CGFloat) {
        for _ in 0..<3 {
            layoutIfNeeded()
            let drawn = cellForRow(at: path).map { $0.convert($0.bounds, to: nil).minY }
            let after = drawn ?? convert(rectForRow(at: path), to: nil).minY
            let delta = after - before
            guard abs(delta) > 0.5 else { return }
            let minOffset = -adjustedContentInset.top
            let maxOffset = max(minOffset, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let target = min(maxOffset, max(minOffset, contentOffset.y + delta))
            guard abs(target - contentOffset.y) > 0.25 else { return }
            contentOffset.y = target
        }
    }
}

/// A loading row: one Fill 3 bar of a given width, VoiceOver silent (the table announces "Loading …").
final class MenusSkeletonCell: UITableViewCell {
    static let reuse = "menus.skeleton"
    private let bar = UIView()
    private var fraction: CGFloat = 0.5

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        bar.backgroundColor = .tertiarySystemFill
        bar.layer.cornerRadius = 5
        bar.layer.cornerCurve = .continuous
        contentView.addSubview(bar)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(fraction: CGFloat) {
        self.fraction = fraction
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = contentView.layoutMargins.left
        bar.frame = CGRect(x: inset, y: (contentView.bounds.height - 16) / 2, width: (contentView.bounds.width - 2 * inset) * fraction, height: 16)
    }
}

/// Section headers in Footnote, label-2 (spec 1x §7.3), as typed (no capitals).
final class MenusSectionHeader: UITableViewHeaderFooterView {
    static let reuse = "menus.header"

    func configure(_ title: String) {
        var content = UIListContentConfiguration.header().hqScaled()
        content.text = title
        content.textProperties.font = HQFont.preferred(.footnote)
        content.textProperties.color = ChatPalette.label2
        content.textProperties.transform = .none
        contentConfiguration = content.hqMacSectionHeader()   // [mac] Stress test 2026-10-28 #52
        accessibilityTraits = .header
    }
}

/// The HUD (S:ui-kit/hud.ts): a top-centre glass capsule confirming something you can't see ("Copied"), 1.5 s, not
/// interactive, announced. Shown over the given screen's view (the chat, or the sheet the copy came from). One at a time.
enum MenusHUD {
    private static weak var current: UIView?

    /// `seconds` nil: it stays until `hide(_:)` (a "Preparing to Share…" HUD that the answer takes down).
    @discardableResult
    static func show(_ text: String, symbol: String? = "checkmark", in view: UIView? = nil, seconds: Double? = 1.5) -> UIView? {
        guard let host = view else { return nil }
        current?.removeFromSuperview()
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        glass.accessibilityIdentifier = "menus.hud"
        glass.isAccessibilityElement = true
        glass.accessibilityLabel = text
        let label = UILabel()
        label.text = text
        label.font = .menusFont(.subheadline, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label      // the skin's ink, as PagesHUD
        let row = UIStackView(arrangedSubviews: [])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        if let symbol {
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)))
            image.tintColor = HQPalette.label
            row.addArrangedSubview(image)
        }
        row.addArrangedSubview(label)
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        glass.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            glass.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            glass.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        current = glass
        glass.alpha = 0
        UIView.animate(withDuration: 0.2) { glass.alpha = 1 }   // motion-ok: opacity only
        HQAnnounce.say(text)
        guard var seconds else { return glass }
        #if DEBUG
        // UI tests (`-HQDebugHUDSeconds 6`): a busy simulator can take longer than the HUD lasts to answer a query.
        let debugSeconds = UserDefaults.standard.double(forKey: "HQDebugHUDSeconds")
        if debugSeconds > 0 { seconds = debugSeconds }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { hide(glass) }
        return glass
    }

    static func hide(_ hud: UIView?) {
        guard let hud, hud.superview != nil else { return }
        UIView.animate(withDuration: 0.25, animations: { hud.alpha = 0 }) { _ in hud.removeFromSuperview() }   // motion-ok: opacity only
    }
}

extension UIFont {
    /// A text style's font at another weight, scaling with Dynamic Type.
    static func menusFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = HQFont.preferred(style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return UIFontMetrics(forTextStyle: style).scaledFont(for: HQFont.face(ofSize: base.pointSize, weight: weight))
    }
}
