// [terminal] The Terminal page's tabs (a tester, Discord 2026-11-04: "adding multiple shells would be neat (tabs
// etc.)"). Each tab is one shell on the computer: its own screen, its own socket, its own 32-hex session name (kept in
// TerminalSettings, so the tabs come back with their shells within the computer's 15 minutes). The strip shows once
// there are two: tap a tab to bring it in front, ✕ on the one in front (or hold any tab) to close it.
// a tester again (2026-11-05): "possibility to name tabs" and "to reorder tabs". Hold a tab for Rename Tab…, Move Left and
// Move Right.

import SwiftTerm
import UIKit

@MainActor final class TerminalTab {
    var session: String
    let view: HQTerminalView
    var connection: TerminalConnection?
    /// Nil until it first dials.
    var phase: TerminalConnection.Phase?
    /// End Shell was chosen here: the card says so rather than the exit code the hang-up gave.
    var endedHere = false
    /// New Shell while one is open: the next shell starts once this one has ended.
    var newAfterEnd = false
    /// Close Tab: the tab goes once its shell has ended.
    var closing = false
    /// What the program in it called the window (OSC 0/2), as the page's subtitle shows.
    var title = ""
    /// What the person named it (hold › Rename Tab…), "" when it goes by `name`.
    var customName = ""

    init(session: String, customName: String = "") {
        self.session = session
        self.customName = customName
        view = HQTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), font: TerminalSettings.font())
        TerminalSettings.applyFont(to: view)
    }

    /// The name its program or shell gives it: the program's title, else the shell's ("zsh"), else nil.
    var name: String? {
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        let shell = connection?.shell ?? ""
        return shell.isEmpty ? nil : (shell as NSString).lastPathComponent
    }

    /// What follows starts again from the top of what the computer kept (or a new shell): an empty screen first. Fed,
    /// so it lands in order with the output (RIS, then erase saved lines).
    func clearScreen() {
        view.feed(text: "\u{1b}c\u{1b}[3J")
    }
}

/// The row of tabs over the screens, on the panel's dark grey. The tab in front is filled and carries ✕.
final class TerminalTabStrip: UIView {
    static let height: CGFloat = 44

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    /// A tab moved: from its place to its place among the others (the index it has once moved).
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var shown: (titles: [String], current: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "terminal.tabs"
        clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        addSubview(scroll)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        scroll.addSubview(row)
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = UIColor(white: 1, alpha: 0.1)
        addSubview(rule)
        // [mac] Mac polish 2026-11-06 #121: a pixel of the window's own display, kept right when the window moves to a
        // display of another scale (as the Helpers divider, Mac audit #12); UIScreen.main's scale was the main display's.
        let ruleHeight = rule.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1))
        registerForTraitChanges([UITraitDisplayScale.self]) { (strip: TerminalTabStrip, _) in
            ruleHeight.constant = 1 / max(strip.traitCollection.displayScale, 1)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            ruleHeight,
        ])
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(titles: [String], current: Int) {
        if let shown, shown.titles == titles, shown.current == current { return }
        shown = (titles, current)
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            row.addArrangedSubview(chip(title, index: index, count: titles.count, front: index == current))
        }
        layoutIfNeeded()
        if row.arrangedSubviews.indices.contains(current) {
            let front = row.arrangedSubviews[current]
            scroll.scrollRectToVisible(front.convert(front.bounds, to: scroll).insetBy(dx: -8, dy: 0), animated: false)
        }
    }

    private func chip(_ title: String, index: Int, count: Int, front: Bool) -> UIView {
        let desktop = Theme.isDesktop
        var config = front ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = title
        config.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
        config.baseForegroundColor = front ? .white : UIColor(white: 1, alpha: 0.62)
        config.cornerStyle = desktop ? .fixed : .capsule
        config.background.cornerRadius = desktop ? DesktopRows.radius : 0
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: front ? 34 : 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = HQFont.mono(ofSize: 13, weight: front ? .semibold : .regular)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "terminal.tab.\(index + 1)"
        button.accessibilityLabel = title
        button.accessibilityValue = "Tab \(index + 1) of \(count)"
        if front { button.accessibilityTraits.insert(.selected) }
        button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .primaryActionTriggered)
        // Hold a tab to name, move or close it (any tab, not only the one in front). The button's own menu: a context
        // menu interaction (the only hold a drag can start from) puts the keyboard away while it's up.
        let first = index == 0, last = index == count - 1
        button.menu = menu(index, count: count)
        var actions = [UIAccessibilityCustomAction(name: "Rename") { [weak self] _ in self?.onRename?(index); return true }]
        if !first { actions.append(UIAccessibilityCustomAction(name: "Move Left") { [weak self] _ in self?.onMove?(index, index - 1); return true }) }
        if !last { actions.append(UIAccessibilityCustomAction(name: "Move Right") { [weak self] _ in self?.onMove?(index, index + 1); return true }) }
        button.accessibilityCustomActions = actions
        NSLayoutConstraint.activate([
            // [ui-sizing] At least 32: its label follows UI Scale, and at 150 % it was cut in a fixed 32 pt chip.
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: front ? 88 : 56),
        ])
        guard front else { return button }
        // ✕ inside the tab in front, its own 44 pt target at the tab's end (audit 10-18: it was 32): beside the tab's
        // button in one box, not in it, so VoiceOver and UI tests find it. The box is the strip's full height, so the
        // target reaches past the 32 pt tab above and below.
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(button)
        var x = UIButton.Configuration.plain()
        x.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        x.baseForegroundColor = UIColor(white: 1, alpha: 0.8)
        x.contentInsets = .zero
        let close = UIButton(configuration: x)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.accessibilityLabel = "Close Tab"
        close.accessibilityIdentifier = "terminal.tab.close"
        close.addAction(UIAction { [weak self] _ in self?.onClose?(index) }, for: .primaryActionTriggered)
        box.addSubview(close)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: Self.height),
            close.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])
        return box
    }
}

// MARK: Holding a tab

extension TerminalTabStrip {
    private func menu(_ index: Int, count: Int) -> UIMenu {
        let first = index == 0, last = index == count - 1
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Rename Tab…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?(index) },
                UIAction(title: "Move Left", image: UIImage(systemName: "arrow.left"), attributes: first ? .disabled : []) { [weak self] _ in
                    self?.onMove?(index, index - 1)
                },
                UIAction(title: "Move Right", image: UIImage(systemName: "arrow.right"), attributes: last ? .disabled : []) { [weak self] _ in
                    self?.onMove?(index, index + 1)
                },
            ]),
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onClose?(index)
            },
        ])
    }
}
