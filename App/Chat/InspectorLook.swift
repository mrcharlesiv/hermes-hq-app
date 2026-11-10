import SwiftUI
import UIKit

/// [inspector] Owner 2026-11-09, on the Mac's right panel (Info, Steps, Files, Helpers): "ugly … the way it's showing
/// all this information is just bad". Each tab was a page borrowed from an iPhone sheet and kept that sheet's look: a
/// card of stacked labels, a chat bubble with a face, bold rows with no rule, another card. In the panel the four now
/// share one look, an inspector's (Xcode's, Finder's Get Info): no cards, the panel's own margin, one text size with a
/// smaller grey detail under or beside it, a hairline between rows, and a grey summary line above a list.
/// The sheets on the iPhone and iPad (and the Mac's own sheets) keep their looks.
@MainActor enum InspectorLook {
    /// The panel's side margin, which every tab's rows start and end at.
    static let margin: CGFloat = 16
    /// A row's words.
    static var textFont: UIFont { HQFont.preferred(.subheadline) }
    /// A label beside a value: the row's size, in the secondary colour.
    static var labelFont: UIFont { HQFont.preferred(.subheadline) }
    /// The grey line under a row's words, a time at its end, the summary above a list.
    static var detailFont: UIFont { HQFont.preferred(.footnote) }

    /// The hairline between rows: the panes' own line on the Mac (the panel is the Mac's; the rest only compiles it).
    static var rule: UIColor {
        #if targetEnvironment(macCatalyst)
        HQPalette.paneLine
        #else
        ChatPalette.separator
        #endif
    }

    /// A table in the panel: no card and no page colour of its own, hairlines from margin to margin.
    static func dress(_ table: UITableView) {
        table.backgroundColor = .clear
        table.separatorStyle = .singleLine
        table.separatorColor = rule
        table.separatorInset = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
        table.separatorInsetReference = .fromCellEdges
        table.cellLayoutMarginsFollowReadableWidth = false
        table.sectionHeaderTopPadding = 0
    }

    /// The grey line above a tab's list ("4 steps · 18s", a folder's trail), as a table's header view.
    static func summary(_ text: NSAttributedString) -> UIView {
        let label = UILabel()
        label.font = detailFont
        label.textColor = HQPalette.label2
        label.attributedText = text
        label.lineBreakMode = .byTruncatingMiddle
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: (detailFont.lineHeight + 12).rounded(.up)))
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -margin),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
        ])
        view.isAccessibilityElement = true
        view.accessibilityLabel = text.string
        return view
    }

    static func summary(_ text: String) -> UIView { summary(NSAttributedString(string: text)) }
}

extension Font {
    /// [inspector] The panel's sizes for its SwiftUI rows.
    @MainActor static var inspectorText: Font { Font(InspectorLook.textFont as CTFont) }
    @MainActor static var inspectorDetail: Font { Font(InspectorLook.detailFont as CTFont) }
}
