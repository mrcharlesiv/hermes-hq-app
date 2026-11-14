// [mac-tools] Owner 2026-11-09 (the Tools sketch, "go ahead with what you sketched"): Files and Changes on the Mac are
// a table, as the Finder's list view, not a phone's grouped cards. A path trail and the columns' names stay at the
// top, the rows are one compact line each (the file's name, then its kind; a change's status and its lines), a folder
// opens in place, and the file on show beside the table keeps its row marked. The bot's pop-up and the folder's menu
// are in the bar. The parts here are drawn by `MoreWorkspaceController` when it is that table (`isTable`).
//
// Hermes lists a folder as names and "is a folder" only (`/api/fs/list`): there is no size or date to show, so the
// columns are Name and Kind.

import UIKit

@MainActor enum MacFilesTable {
    static var rowHeight: CGFloat { HQFont.scaled(30).rounded() }
    static var trailHeight: CGFloat { HQFont.scaled(34).rounded() }
    static var columnsHeight: CGFloat { HQFont.scaled(24).rounded() }
    static let margin: CGFloat = 16
    /// The glyph's room before a name.
    static var glyph: CGFloat { HQFont.scaled(26).rounded() }
    /// The trailing columns. Files: Kind. Changes: Status, Lines. Each widens with the table, between two limits.
    enum Column {
        case kind, status, lines
        func width(in table: CGFloat) -> CGFloat {
            let (share, least, most): (CGFloat, CGFloat, CGFloat) = switch self {
            case .kind: (0.24, 112, 260)
            case .status: (0.16, 84, 190)
            case .lines: (0.12, 72, 130)
            }
            let width = min(HQFont.scaled(most), max(HQFont.scaled(least), table * share))
            // [Mac UI check 2026-11-13] In a narrow list (a file open beside it) Kind kept its least width and squeezed
            // Name to a few letters: the kind gives way first (a long one is cut at its end), never past a third.
            if self == .kind { return min(width, table / 3).rounded() }
            return width.rounded()
        }
    }

    static var text: UIFont { HQFont.preferred(.subheadline) }
    static var detail: UIFont { HQFont.preferred(.footnote) }

    /// Every other row's faint band, inset and rounded as the selection's box is.
    static let stripe = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.035) : UIColor(white: 0, alpha: 0.03)
    }

    /// Where the trailing columns start in a row `width` wide: each column's leading x, left to right.
    static func columns(_ columns: [Column], in width: CGFloat) -> (starts: [CGFloat], widths: [CGFloat]) {
        let widths = columns.map { $0.width(in: width) }
        var x = width - margin - widths.reduce(0, +)
        return (widths.map { w in defer { x += w }; return x }, widths)
    }
}

// MARK: - A row

final class MacFileRowCell: UITableViewCell {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let columnLabels = [UILabel(), UILabel()]
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var columns: [MacFilesTable.Column] = []
    var striped = false { didSet { if striped != oldValue { setNeedsUpdateConfiguration() } } }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.contentMode = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.adjustsFontForContentSizeCategory = true
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        for view in [icon, nameLabel, spinner] + columnLabels { contentView.addSubview(view) }
        for label in columnLabels {
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = true
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `columns`: each trailing column's words and width, left to right (at most two).
    func set(symbol: String, tint: UIColor, name: NSAttributedString, columns: [(NSAttributedString, MacFilesTable.Column)], busy: Bool) {
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: MacFilesTable.text))
        icon.tintColor = tint
        icon.isHidden = busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        nameLabel.attributedText = name
        self.columns = columns.map(\.1)
        for (index, label) in columnLabels.enumerated() {
            label.isHidden = index >= columns.count
            label.attributedText = index < columns.count ? columns[index].0 : nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ view: UIView, x: CGFloat, width: CGFloat) {
            view.frame = CGRect(x: rightToLeft ? bounds.width - x - width : x, y: 0, width: max(0, width), height: bounds.height)
        }
        let margin = MacFilesTable.margin, glyph = MacFilesTable.glyph
        let (starts, widths) = MacFilesTable.columns(columns, in: bounds.width)
        place(icon, x: margin, width: glyph - 6)
        spinner.center = icon.center
        let nameEnd = (starts.first ?? bounds.width - margin) - 10
        place(nameLabel, x: margin + glyph, width: nameEnd - margin - glyph)
        for (index, x) in starts.enumerated() { place(columnLabels[index], x: x, width: widths[index] - (index == starts.count - 1 ? 0 : 8)) }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        #if targetEnvironment(macCatalyst)
        var background = MacSelection.listRow(state)
        if !state.isSelected, !state.isHighlighted, striped {
            background.backgroundColor = MacFilesTable.stripe
            background.backgroundInsets = MacSelection.insets
            background.cornerRadius = MacSelection.radius
        }
        backgroundConfiguration = background
        #endif
    }
}

// MARK: - The trail and the columns' names

/// The table's sticky top: the folder's trail (each folder a button back to it), what is listed ("12 items"), and
/// under them the columns' names over a hairline.
final class MacFilesHeaderView: UIView {
    struct Crumb { var name: String; var path: String?; var tip: String? = nil }

    var onCrumb: ((String) -> Void)?
    private let scroll = UIScrollView()
    private let trail = UIStackView()
    private let countLabel = UILabel()
    private let nameTitle = UILabel()
    private let columnTitles = [UILabel(), UILabel()]
    private let line = UIView()
    private var columns: [MacFilesTable.Column] = []
    private var showsColumns = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HQPalette.page
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        trail.axis = .horizontal
        trail.alignment = .center
        trail.spacing = 0
        scroll.addSubview(trail)
        countLabel.font = MacFilesTable.detail
        countLabel.textColor = HQPalette.label2
        countLabel.textAlignment = .right
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.accessibilityIdentifier = "workspace.count"
        line.backgroundColor = HQPalette.separator
        for label in [nameTitle] + columnTitles {
            label.font = MacFilesTable.detail.pagesWeight(.medium)
            label.textColor = HQPalette.label2
            label.adjustsFontForContentSizeCategory = true
        }
        nameTitle.text = "Name"
        for view in [scroll, countLabel, nameTitle, line] + columnTitles { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func height(columns: Bool) -> CGFloat { MacFilesTable.trailHeight + (columns ? MacFilesTable.columnsHeight : 0) }

    func set(crumbs: [Crumb], count: String, columns: [(String, MacFilesTable.Column)]?) {
        trail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, crumb) in crumbs.enumerated() {
            let last = index == crumbs.count - 1
            if index > 0 {
                let arrow = UIImageView(image: UIImage(systemName: "chevron.right",
                                                       withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.caption2), scale: .small)))
                arrow.tintColor = HQPalette.label3
                arrow.setContentHuggingPriority(.required, for: .horizontal)
                trail.addArrangedSubview(arrow)
            }
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            config.attributedTitle = AttributedString(crumb.name, attributes: AttributeContainer([
                .font: last ? MacFilesTable.text.pagesWeight(.semibold) : MacFilesTable.text,
                .foregroundColor: last ? HQPalette.label : HQPalette.label2]))
            if index == 0 {
                config.image = UIImage(systemName: "folder")
                config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: MacFilesTable.text, scale: .medium)
                config.imagePadding = MacFilesTable.glyph - 20
                config.baseForegroundColor = HQPalette.tint
            }
            config.titleLineBreakMode = .byTruncatingMiddle
            let button = UIButton(configuration: config)
            button.isUserInteractionEnabled = !last && crumb.path != nil
            button.accessibilityIdentifier = "workspace.crumb.\(index)"
            button.accessibilityLabel = crumb.name
            if let path = crumb.path {
                button.toolTip = crumb.tip ?? path
                button.addAction(UIAction { [weak self] _ in self?.onCrumb?(path) }, for: .primaryActionTriggered)
            }
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            trail.addArrangedSubview(button)
        }
        countLabel.text = count
        showsColumns = columns != nil
        self.columns = columns?.map(\.1) ?? []
        for (index, label) in columnTitles.enumerated() {
            label.isHidden = index >= (columns?.count ?? 0)
            label.text = index < (columns?.count ?? 0) ? columns?[index].0 : nil
        }
        nameTitle.isHidden = !showsColumns
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = MacFilesTable.margin, top = MacFilesTable.trailHeight
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func flip(_ rect: CGRect) -> CGRect {
            rightToLeft ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        let countWidth = min(bounds.width * 0.4, ceil(countLabel.intrinsicContentSize.width))
        countLabel.frame = flip(CGRect(x: bounds.width - margin - countWidth, y: 0, width: countWidth, height: top))
        // The crumbs' own 6 pt inset puts the first glyph on the rows' margin.
        let room = bounds.width - (margin - 6) - margin - countWidth - (countWidth > 0 ? 10 : 0)
        scroll.frame = flip(CGRect(x: margin - 6, y: 0, width: max(0, room), height: top))
        let fitted = trail.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        trail.frame = CGRect(x: 0, y: 0, width: fitted.width, height: top)
        scroll.contentSize = CGSize(width: fitted.width, height: top)
        // A deep folder: the trail's end (where you are) stays in view.
        scroll.contentOffset.x = max(0, fitted.width - scroll.bounds.width)
        let pixel = 1 / max(1, traitCollection.displayScale)
        line.frame = CGRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel)
        guard showsColumns else { return }
        let height = bounds.height - top
        let (starts, widths) = MacFilesTable.columns(columns, in: bounds.width)
        let nameEnd = (starts.first ?? bounds.width - margin) - 10
        nameTitle.frame = flip(CGRect(x: margin + MacFilesTable.glyph, y: top, width: max(0, nameEnd - margin - MacFilesTable.glyph), height: height - 2))
        for (index, x) in starts.enumerated() {
            columnTitles[index].frame = flip(CGRect(x: x, y: top, width: widths[index], height: height - 2))
        }
    }
}

// MARK: - The bar's leading words and pop-up

/// A tool's bar on the Mac: its name, then (when there is something to pick) a pop-up beside it, as Kanban's board.
@MainActor enum MacToolBar {
    static func lead(title: String, popUp: UIView?) -> UIBarButtonItem {
        let label = UILabel()
        label.font = MacType.pageTitle
        label.textColor = HQPalette.label
        label.adjustsFontForContentSizeCategory = true
        label.text = title
        label.accessibilityTraits = .header
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label] + (popUp.map { [$0] } ?? []))
        stack.spacing = 12
        stack.alignment = .center
        // As far in as a tab's own title (`MacPlaceTitle`): the bar starts its items 10 pt nearer the edge.
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0)
        let lead = UIBarButtonItem(customView: stack)
        lead.hidesSharedBackground = true   // words and a pop-up on the bar, not a glass button
        return lead
    }

    static func popUp(identifier: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 7)
        config.cornerStyle = .fixed
        config.background.cornerRadius = MacField.radius
        config.background.strokeWidth = 1
        config.background.strokeColor = MacPush.stroke
        config.background.backgroundColor = MacPush.fill
        config.titleLineBreakMode = .byTruncatingMiddle
        config.image = UIImage(systemName: "chevron.up.chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2).applying(UIImage.SymbolConfiguration(weight: .semibold)))
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = HQPalette.label2
        button.accessibilityIdentifier = identifier
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: MacForm.controlHeight).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return button
    }

    static func setTitle(_ title: String, on button: UIButton) {
        button.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: HQFont.preferred(.subheadline), .foregroundColor: HQPalette.label]))
    }
}
