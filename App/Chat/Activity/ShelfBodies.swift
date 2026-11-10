import UIKit

// The opened cards' contents (docs/spec/1x-activity.md §4.1, §5.1, §6.3). Text on glass uses only label / label-2 at
// Footnote size or larger (owner: tertiary greys wash out on glass). Wrapping rows keep 12–14 pt vertical padding and
// trailing actions sit apart from the text (M:row-padding-feedback.md). Views are kept by id and updated in place, so a
// live update never rebuilds what is on screen (no flashing, no doubled text — M:subagent-card-glass.md).

enum ShelfText {
    static var footnote: UIFont { HQFont.preferred(.footnote) }
    static var footnoteBold: UIFont {
        let f = HQFont.preferred(.footnote)
        return HQFont.face(ofSize: f.pointSize, weight: .semibold)
    }
    static var caption: UIFont { HQFont.preferred(.caption1) }
    static var subheadline: UIFont { HQFont.preferred(.subheadline) }

    static func label(_ font: UIFont, color: UIColor = ChatPalette.label, lines: Int = 0) -> UILabel {
        let l = UILabel()
        l.font = font
        l.adjustsFontForContentSizeCategory = true
        l.textColor = color
        l.numberOfLines = lines
        l.lineBreakMode = .byWordWrapping
        return l
    }

    static var isLarge: Bool { UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory }
}

/// An opened card's body: `layoutRevision` moves only when something that can change its height changed, so the piece
/// measures it once per change (a running child's events, the shelf's own updates and the timers don't re-measure up
/// to 16 KiB of transcript each time).
@MainActor protocol ShelfMeasuredBody: UIView {
    var layoutRevision: Int { get }
}

/// Bumps a revision when the hash of a body's inputs changes.
struct ShelfRevision {
    private(set) var value = 0
    private var last: Int?
    mutating func note(_ hash: Int) {
        guard hash != last else { return }
        last = hash
        value &+= 1
    }
}

/// A row that highlights on press (fill-4) inside an opened card.
class ShelfRowControl: UIControl {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? ChatPalette.fill4 : .clear }
    }
}

// Subagents (§4.1): SubagentBodies.swift.

// MARK: - Tasks (§5.1)

final class TasksBody: UIView, ShelfMeasuredBody {
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }
    private let stack = UIStackView()
    private var rows: [String: TaskRowView] = [:]
    private var order: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `historical`: Previous tasks (an in-progress item shows the pending ring).
    func update(_ todos: [TodoItem], historical: Bool) {
        var h = Hasher()
        h.combine(todos); h.combine(historical)
        revision.note(h.finalize())
        let tree = TodoRules.tree(todos)
        let ids = tree.map(\.item.id)
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for entry in tree {
            let row = rows[entry.item.id] ?? { let r = TaskRowView(); rows[entry.item.id] = r; return r }()
            row.update(entry.item, depth: min(4, entry.depth), historical: historical)
        }
        if ids != order {
            order = ids
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            for id in ids { if let r = rows[id] { stack.addArrangedSubview(r) } }
        }
    }
}

final class TaskRowView: UIView {
    private let glyph = UIImageView()
    private let spinner = GlyphSpinner(style: .braille, color: ChatPalette.label2, size: HQFont.symbolSize(14, like: .subheadline, cap: 24))
    private let title = ShelfText.label(ShelfText.footnote)
    private var indent: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.contentMode = .scaleAspectFit
        for v: UIView in [glyph, spinner, title] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        indent = glyph.leadingAnchor.constraint(equalTo: leadingAnchor)
        // [ui-sizing 2026-11-09] A to-do is read, not tapped: 6 pt over and under (as a subagent's steps), no 44 pt
        // minimum. Ten to-dos took about 440 pt. The glyph's box is the spinner's size, so the two don't jump.
        let side = max(16, HQFont.symbolSize(14, like: .subheadline, cap: 24))
        NSLayoutConstraint.activate([
            indent,
            glyph.widthAnchor.constraint(equalToConstant: side), glyph.heightAnchor.constraint(equalToConstant: side),
            glyph.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -4),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ item: TodoItem, depth: Int, historical: Bool) {
        indent.constant = CGFloat(depth) * 4
        if title.text != item.content { title.text = item.content }
        let done = item.status == .completed || item.status == .cancelled
        title.textColor = done ? ChatPalette.label2 : ChatPalette.label
        let config = UIImage.SymbolConfiguration(pointSize: HQFont.symbolSize(15, like: .subheadline, cap: 24), weight: .regular)   // [ui-sizing] grows with the text
        var spinning = false
        switch item.status {
        case .pending:
            glyph.image = UIImage(systemName: "circle.dashed", withConfiguration: config); glyph.tintColor = ChatPalette.label2
        case .inProgress:
            if historical {
                glyph.image = UIImage(systemName: "circle.dashed", withConfiguration: config); glyph.tintColor = ChatPalette.label2
            } else {
                spinning = true
            }
        case .completed:
            glyph.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: config); glyph.tintColor = ChatPalette.green
        case .cancelled:
            glyph.image = UIImage(systemName: "circle.slash", withConfiguration: config); glyph.tintColor = ChatPalette.label3
        }
        glyph.isHidden = spinning
        spinner.isHidden = !spinning
        let status: String = {
            switch item.status {
            case .pending: return "pending"
            case .inProgress: return historical ? "pending" : "in progress"
            case .completed: return "completed"
            case .cancelled: return "cancelled"
            }
        }()
        accessibilityLabel = "\(item.content), \(status)"
    }
}

// MARK: - Goal (§6.3)

final class GoalBody: UIView, ShelfMeasuredBody {
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }
    var onDetails: (() -> Void)?
    var onAddCriterion: (() -> Void)?
    var onClearCriteria: (() -> Void)?
    var onRemoveCriterion: ((Int) -> Void)?
    var onDismissError: (() -> Void)?

    private let stack = UIStackView()
    private let errorLabel = ShelfText.label(ShelfText.footnote, color: ChatPalette.red)
    private let errorClose = UIButton(type: .system)
    private let titleRow = UIStackView()
    private let flag = UIImageView(image: UIImage(systemName: "flag"))
    private let titleLabel = ShelfText.label(ShelfText.subheadline)
    private let reasonLabel = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private let detailsButton = UIButton(type: .system)
    private let separator = UIView()
    private let criteriaHeader = ShelfText.label(ShelfText.footnoteBold, color: ChatPalette.label2)
    private let addButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let criteria = UIStackView()
    private var busy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        // The red failure row with its ✕.
        errorClose.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)), for: .normal)
        errorClose.tintColor = ChatPalette.red
        errorClose.accessibilityLabel = "Close"
        errorClose.addAction(UIAction { [weak self] _ in self?.onDismissError?() }, for: .touchUpInside)
        let errorStack = UIStackView(arrangedSubviews: [errorLabel, errorClose])
        errorStack.alignment = .center
        errorStack.spacing = 8
        errorClose.widthAnchor.constraint(equalToConstant: 44).isActive = true
        errorClose.heightAnchor.constraint(equalToConstant: 44).isActive = true
        errorLabel.accessibilityTraits = .staticText
        stack.addArrangedSubview(errorStack)
        // Title.
        flag.tintColor = ChatPalette.label2
        flag.contentMode = .scaleAspectFit
        flag.setContentHuggingPriority(.required, for: .horizontal)
        titleRow.addArrangedSubview(flag)
        titleRow.addArrangedSubview(titleLabel)
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(reasonLabel)
        var details = UIButton.Configuration.plain()
        details.title = "View Details"
        details.baseForegroundColor = ChatPalette.tintText
        details.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        details.titleLineBreakMode = .byTruncatingTail
        detailsButton.configuration = details
        detailsButton.contentHorizontalAlignment = .leading
        detailsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        detailsButton.addAction(UIAction { [weak self] _ in self?.onDetails?() }, for: .touchUpInside)
        stack.addArrangedSubview(detailsButton)
        separator.backgroundColor = ChatPalette.separator
        separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        stack.addArrangedSubview(separator)
        for (button, title, color) in [(addButton, "Add Criterion", ChatPalette.tintText), (clearButton, "Clear All Criteria", ChatPalette.red)] {
            var c = UIButton.Configuration.plain()
            c.title = title
            c.baseForegroundColor = color
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a; a.font = ShelfText.footnote; return a
            }
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
            c.titleLineBreakMode = .byTruncatingTail
            button.configuration = c
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        addButton.addAction(UIAction { [weak self] _ in self?.onAddCriterion?() }, for: .touchUpInside)
        clearButton.addAction(UIAction { [weak self] _ in self?.onClearCriteria?() }, for: .touchUpInside)
        let headerRow = UIStackView(arrangedSubviews: [criteriaHeader, addButton, clearButton])
        headerRow.alignment = .center
        headerRow.spacing = 4
        criteriaHeader.numberOfLines = 0
        criteriaHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        criteriaHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if ShelfText.isLarge {
            // At accessibility sizes the actions go under the header (labels never cut).
            headerRow.axis = .vertical
            headerRow.alignment = .leading
        }
        stack.addArrangedSubview(headerRow)
        criteria.axis = .vertical
        stack.addArrangedSubview(criteria)
        accessibilityIdentifier = "chat.goal.card"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ goal: GoalSnapshot, entry: ControlEntry) {
        var h = Hasher()
        h.combine(goal); h.combine(entry)
        revision.note(h.finalize())
        busy = entry.pendingAction != nil
        let error = entry.actionError
        errorLabel.superview?.isHidden = error == nil
        errorLabel.text = error
        if titleLabel.text != goal.title { titleLabel.text = goal.title }
        let reason = ControlRules.reason(goal)
        reasonLabel.text = reason
        reasonLabel.isHidden = reason == nil
        detailsButton.isHidden = !ControlRules.hasDetails(goal)
        criteriaHeader.text = "Criteria · \(goal.subgoals.count)"
        addButton.isHidden = goal.status == .done
        clearButton.isHidden = goal.subgoals.isEmpty
        for b in [addButton, clearButton, detailsButton] { b.isEnabled = !busy || b === detailsButton }
        // Criteria rows (rebuilt only when they changed).
        let current = criteria.arrangedSubviews.compactMap { ($0 as? CriterionRow)?.text }
        if current != goal.subgoals {
            for v in criteria.arrangedSubviews { criteria.removeArrangedSubview(v); v.removeFromSuperview() }
            for (i, text) in goal.subgoals.enumerated() {
                let row = CriterionRow(text: text)
                row.onRemove = { [weak self] in self?.onRemoveCriterion?(i + 1) }
                criteria.addArrangedSubview(row)
            }
        }
        criteria.arrangedSubviews.forEach { ($0 as? CriterionRow)?.setBusy(busy) }
    }
}

/// One criterion: a pending ring, the text (wraps), Copy and ✕ 16 pt apart from the text.
final class CriterionRow: UIView {
    let text: String
    var onRemove: (() -> Void)?
    private let copy = UIButton(type: .system)
    private let remove = UIButton(type: .system)

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        let ring = UIImageView(image: UIImage(systemName: "circle.dashed", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)))
        ring.tintColor = ChatPalette.label2
        let label = ShelfText.label(ShelfText.footnote)
        label.text = text
        let small = UIImage.SymbolConfiguration(textStyle: .footnote)
        copy.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: small), for: .normal)
        copy.tintColor = ChatPalette.label2
        copy.accessibilityLabel = "Copy criterion"
        copy.addAction(UIAction { _ in
            UIPasteboard.general.string = text
            Haptics.play(.success)
            HQAnnounce.say("Criterion copied to clipboard")
        }, for: .touchUpInside)
        remove.setImage(UIImage(systemName: "xmark", withConfiguration: small), for: .normal)
        remove.tintColor = ChatPalette.label2
        remove.accessibilityLabel = "Remove criterion"
        remove.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .touchUpInside)
        for v: UIView in [ring, label, copy, remove] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            label.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -16),
            copy.widthAnchor.constraint(equalToConstant: 44), copy.heightAnchor.constraint(equalToConstant: 44),
            copy.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: copy.trailingAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.widthAnchor.constraint(equalToConstant: 44), remove.heightAnchor.constraint(equalToConstant: 44),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.isAccessibilityElement = true
        accessibilityElements = [label, copy, remove]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setBusy(_ busy: Bool) { remove.isEnabled = !busy }
}
