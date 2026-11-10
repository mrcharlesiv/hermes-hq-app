import UIKit

// The opened Subagents card (docs/spec/1x-activity.md §4.1). Owner, 2026-10-29: the card and what a tapped subagent
// opened "sucks" on the phone and the desktop app. The card is now a list of helpers, finished ones included (a check,
// a cross or a stop mark in place of the spinner, their time frozen), and a tapped helper opens its own page in the card:
// goal and status, the Steer row while it still runs, its result, a timeline of its steps, the files it touched and its
// output. On the phone the page replaces the list (a back row returns); where the card is wide (the
// Mac, iPad) the list stays on the left and the page sits beside it. Still one scroller, inline above the composer
// (M:subagent-card-glass.md: the owner rejected a sheet); views are kept and updated in place (no flashing).

final class SubagentsBody: UIView, UITextFieldDelegate, ShelfMeasuredBody {
    var onSelect: ((String?) -> Void)?
    var onSteer: ((String, String) -> Void)?
    var onStop: ((String) -> Void)?
    var onDraftChange: ((String, String) -> Void)?
    /// The Steer field gained or lost focus.
    var onEditingChange: (() -> Void)?
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }

    /// The card is wide enough for the list and the page side by side.
    static let wideWidth: CGFloat = 600

    private let stack = UIStackView()
    private let list = UIStackView()
    private let back = SubagentBackRow()
    private let split = UIStackView()
    private let divider = UIView()
    private let pageColumn = UIStackView()
    private let placeholder = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private var rows: [String: SubagentRowView] = [:]
    private let detail = SubagentDetailView()
    private var selected: String?
    private var wide = false
    /// Children whose whole output is shown (folded to its last lines otherwise).
    private var expandedOutput: Set<String> = []
    private var listWidth: NSLayoutConstraint?
    private var dividerHeight: NSLayoutConstraint?
    /// [inspector] The Mac's right panel (`InspectorLook`): flat ruled rows from margin to margin under a grey count
    /// ("3 helpers · 2 working"), not the shelf's rounded bold rows.
    private let panel: Bool
    private var summary: UIView?
    private var summaryText = ""

    init(panel: Bool = false) {
        self.panel = panel
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: panel ? 0 : 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: panel ? 0 : -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        list.axis = .vertical
        list.spacing = panel ? 0 : 2
        split.axis = .horizontal
        split.alignment = .top
        split.spacing = 10
        divider.backgroundColor = ChatPalette.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        // [mac-audit #12] Owner 2026-11-02: a pixel of the window's own display, kept right when the window moves to
        // a display of another scale (a Mac with a 1x monitor beside a 2x one); UIScreen.main's scale was the wrong one.
        let dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale))
        dividerWidth.isActive = true
        registerForTraitChanges([UITraitDisplayScale.self]) { (body: SubagentsBody, _) in
            dividerWidth.constant = 1 / max(1, body.traitCollection.displayScale)
        }
        pageColumn.axis = .vertical
        placeholder.text = "Choose a helper to see its steps."
        placeholder.textAlignment = .center
        back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        detail.field.delegate = self
        detail.field.addTarget(self, action: #selector(draftChanged), for: .editingChanged)
        detail.field.addAction(UIAction { [weak self] _ in self?.onEditingChange?() }, for: [.editingDidBegin, .editingDidEnd])
        detail.send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        detail.stop.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        detail.outputToggle.addTarget(self, action: #selector(outputToggled), for: .touchUpInside)
        accessibilityIdentifier = "chat.subagents.card"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    struct Feedback: Equatable { var text: String; var isError: Bool }

    /// [inspector] "3 helpers · 2 working" over the panel's list (nil off the panel).
    private func countLine(_ children: [SubagentProgress]) -> UIView? {
        guard panel, !children.isEmpty else { return nil }
        var parts = [children.count == 1 ? "1 helper" : "\(children.count) helpers"]
        let working = children.filter { $0.status == .running }.count
        if working > 0 { parts.append("\(working) working") }
        let text = parts.joined(separator: " · ")
        if let summary, text == summaryText { return summary }
        let view = InspectorLook.summary(text)
        view.heightAnchor.constraint(equalToConstant: view.frame.height).isActive = true
        summary = view
        summaryText = text
        return view
    }

    func update(children: [SubagentProgress], selected: String?, tail: SubagentTail?, draft: String, feedback: Feedback?,
                busy: Bool, wide: Bool, width: CGFloat, now: Double) {
        let ids = children.map(\.id)
        let sel = selected.flatMap { ids.contains($0) ? $0 : nil }
        let expanded = sel.map { expandedOutput.contains($0) } ?? false
        var h = Hasher()
        h.combine(children); h.combine(sel); h.combine(tail); h.combine(feedback?.text); h.combine(busy); h.combine(wide)
        h.combine(expanded); h.combine(draft.isEmpty)
        revision.note(h.finalize())
        self.selected = sel
        self.wide = wide
        // Rows, kept by id.
        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        for child in children {
            let row = rows[child.id] ?? {
                let r = SubagentRowView(panel: panel)
                r.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                rows[child.id] = r
                return r
            }()
            row.update(child, picked: wide && child.id == sel, drillIn: !wide, now: now)
        }
        let wantedRows: [UIView] = ids.compactMap { rows[$0] }
        if list.arrangedSubviews != wantedRows {
            for v in list.arrangedSubviews where !wantedRows.contains(v) { list.removeArrangedSubview(v); v.removeFromSuperview() }
            for (i, v) in wantedRows.enumerated() where list.arrangedSubviews.firstIndex(of: v) != i { list.insertArrangedSubview(v, at: i) }
        }
        // Phone: the list, or the page with a back row. Wide: both, side by side. Views already in place stay put (a
        // focused Steer field keeps its keyboard).
        let wantedStack: [UIView]
        if wide {
            let page: UIView = sel == nil ? placeholder : detail
            if pageColumn.arrangedSubviews != [page] { arrange(pageColumn, [page]) }
            if split.arrangedSubviews != [list, divider, pageColumn] { arrange(split, [list, divider, pageColumn]) }
            let w = min(300, max(230, (width * 0.36).rounded()))
            if listWidth == nil { listWidth = list.widthAnchor.constraint(equalToConstant: w) }
            listWidth?.constant = w
            listWidth?.isActive = true
            if dividerHeight == nil {
                dividerHeight = divider.heightAnchor.constraint(equalTo: split.heightAnchor)
                dividerHeight?.isActive = true
            }
            wantedStack = [split]
        } else {
            listWidth?.isActive = false
            wantedStack = sel == nil ? [countLine(children), list].compactMap { $0 } : [back, detail]
        }
        if stack.arrangedSubviews != wantedStack { arrange(stack, wantedStack) }
        back.set(count: children.count, live: children.filter(\.isLive).count)
        if let sel, let child = children.first(where: { $0.id == sel }) {
            detail.update(child, tail: tail, draft: draft, feedback: feedback, busy: busy, expanded: expanded, now: now)
        }
    }

    private func arrange(_ s: UIStackView, _ views: [UIView]) {
        for v in s.arrangedSubviews where !views.contains(v) { s.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, v) in views.enumerated() where s.arrangedSubviews.firstIndex(of: v) != i { s.insertArrangedSubview(v, at: i) }
    }

    /// Ticks the timers (no layout change: the timer columns are fixed).
    func tick(now: Double) {
        rows.values.forEach { $0.tick(now: now) }
        if selected != nil { detail.tick(now: now) }
    }

    @objc private func rowTapped(_ sender: SubagentRowView) {
        Haptics.play(.selection)
        guard let id = rows.first(where: { $0.value === sender })?.key else { return }
        // Wide: the page always shows one; a tap on the picked row keeps it. Phone: the page opens.
        if wide, selected == id { return }
        onSelect?(id)
    }

    @objc private func backTapped() {
        Haptics.play(.selection)
        if detail.field.isFirstResponder { detail.field.resignFirstResponder() }
        onSelect?(nil)
    }

    @objc private func outputToggled() {
        guard let id = selected else { return }
        Haptics.play(.selection)
        if expandedOutput.contains(id) { expandedOutput.remove(id) } else { expandedOutput.insert(id) }
        onSelect?(id)
    }

    @objc private func draftChanged() {
        guard let id = selected else { return }
        detail.refreshSend()
        onDraftChange?(id, detail.field.text ?? "")
    }

    @objc private func sendTapped() {
        guard let id = selected, detail.send.isEnabled else { return }
        let text = (detail.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSteer?(id, text)
    }

    @objc private func stopTapped() {
        guard let id = selected else { return }
        Haptics.play(.rigid)
        onStop?(id)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return false
    }

    /// The Steer field is focused (the card's cap drops to 40 % with the keyboard up).
    var isEditingSteer: Bool { detail.field.isFirstResponder }

    /// The Steer row in `view`'s coordinates (the card scrolls it into sight when the field is focused).
    func steerRowFrame(in view: UIView) -> CGRect? {
        guard detail.window != nil, let row = detail.field.superview, !row.isHidden else { return nil }
        return row.convert(row.bounds, to: view)
    }

    /// What a tap opened, in `view`'s coordinates: the page's top (phone), or the picked row (wide).
    func selectedFrame(in view: UIView) -> CGRect? {
        guard let sel = selected else { return nil }
        if wide, let row = rows[sel], row.window != nil { return row.convert(row.bounds, to: view) }
        guard back.window != nil else { return nil }
        return back.convert(back.bounds, to: view)
    }
}

// MARK: - Status words and marks

enum SubagentLook {
    static func word(_ s: SubagentStatus) -> String {
        switch s {
        case .running: return "Running"
        case .queued: return "Queued"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Stopped"
        }
    }

    static func color(_ s: SubagentStatus) -> UIColor {
        switch s {
        case .running: return GlyphFrames.purple
        case .queued: return ChatPalette.label2
        case .completed: return ChatPalette.green
        case .failed: return ChatPalette.red
        case .interrupted: return ChatPalette.orange
        }
    }

    /// The finished mark in place of the spinner.
    static func symbol(_ s: SubagentStatus) -> String? {
        switch s {
        case .running: return nil
        case .queued: return "clock"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        }
    }

    /// A step's mark: what kind of work the line was.
    static func symbol(_ entry: SubagentStreamEntry) -> String {
        if entry.isError { return "exclamationmark.triangle.fill" }
        switch entry.kind {
        case .thinking: return "brain"
        case .summary: return "checkmark.circle"
        case .progress: return "arrow.turn.down.right"
        case .tool:
            let t = entry.text.lowercased()
            func has(_ words: String...) -> Bool { words.contains { t.hasPrefix($0) || t.contains(" \($0)") } }
            if has("write", "edit", "patch", "create", "apply") { return "pencil" }
            if has("read", "open", "view", "cat") { return "doc.text" }
            if has("search", "grep", "find", "glob", "list") { return "magnifyingglass" }
            if has("terminal", "bash", "shell", "run", "exec", "command") { return "terminal" }
            if has("web", "browse", "fetch", "http", "url") { return "globe" }
            return "wrench.and.screwdriver"
        }
    }

    /// The time a child ran: live, now − start; finished, its stated duration (or its last update).
    static func elapsed(_ child: SubagentProgress, now: Double) -> Int {
        if child.isLive { return Int(now - child.startedAt) }
        if let d = child.durationSeconds, d > 0 { return Int(d.rounded()) }
        return Int(max(0, child.updatedAt - child.startedAt))
    }

    static func image(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
            ?? UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.5))
    }
}

// MARK: - Rows

/// One helper: status (spinner, or a finished mark) · goal (2 lines) · time on the goal's line · › on the phone; its
/// newest step under the goal.
final class SubagentRowView: ShelfRowControl {
    private let spinner = GlyphSpinner(style: .braille, color: GlyphFrames.purple, size: HQFont.symbolSize(15, like: .subheadline, cap: 24))
    private let mark = UIImageView()
    private let title = ShelfText.label(ShelfText.footnoteBold)
    private let subtitle = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 1)
    private let timer = UILabel()
    private let chevron = UIImageView(image: SubagentLook.image("chevron.right", size: 12))
    private var child: SubagentProgress?
    private var picked = false
    private var chevronWidth: NSLayoutConstraint!
    /// [inspector] The Mac's right panel: a flat row at the panel's margin with a rule under it (`InspectorLook`).
    private let panel: Bool
    private let rule = UIView()

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted || picked ? ChatPalette.fill4 : .clear }
    }

    init(panel: Bool = false) {
        self.panel = panel
        super.init(frame: .zero)
        layer.cornerRadius = panel ? 0 : 12
        layer.cornerCurve = .continuous
        if panel {
            title.font = InspectorLook.textFont
            subtitle.font = InspectorLook.detailFont
            rule.backgroundColor = InspectorLook.rule
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.isUserInteractionEnabled = false
            addSubview(rule)
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InspectorLook.margin),
                rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InspectorLook.margin),
                rule.bottomAnchor.constraint(equalTo: bottomAnchor),
                rule.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            ])
        }
        timer.font = HQFont.monoDigitFace(ofSize: ShelfText.footnote.pointSize, weight: .regular)
        timer.textColor = ChatPalette.label2
        timer.textAlignment = .right
        subtitle.lineBreakMode = .byTruncatingTail
        title.lineBreakMode = .byTruncatingTail
        mark.contentMode = .center
        chevron.tintColor = ChatPalette.label2
        chevron.contentMode = .center
        for v: UIView in [spinner, mark, title, subtitle, timer, chevron] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        let timerW = ceil(("00:00" as NSString).size(withAttributes: [.font: timer.font!]).width)
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 10)
        let side: CGFloat = panel ? InspectorLook.margin : 10
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: panel ? 40 : 44),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            spinner.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            mark.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -ShelfText.footnote.capHeight / 2),
            title.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: panel ? 8 : 12),
            title.trailingAnchor.constraint(equalTo: timer.leadingAnchor, constant: -8),
            timer.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            timer.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            timer.widthAnchor.constraint(equalToConstant: timerW),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronWidth,
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: panel ? 1 : 3),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: panel ? -8 : -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ child: SubagentProgress, picked: Bool, drillIn: Bool, now: Double) {
        self.child = child
        self.picked = picked
        layer.cornerRadius = panel ? 0 : Theme.isDesktop ? 4 : 12
        backgroundColor = picked ? ChatPalette.fill4 : .clear
        if title.text != child.goal { title.text = child.goal }
        title.numberOfLines = panel ? 1 : ShelfText.isLarge ? 0 : 2
        let line: String = {
            if !child.isLive, let s = child.summary, !s.isEmpty { return s }
            return child.stream.last?.text ?? (child.status == .queued ? "Queued" : "Waiting for activity")
        }()
        if subtitle.text != line { subtitle.text = line }
        spinner.isHidden = child.status != .running
        if let name = SubagentLook.symbol(child.status) {
            mark.image = SubagentLook.image(name, size: HQFont.symbolSize(14, like: .footnote, cap: 22))
            mark.tintColor = SubagentLook.color(child.status)
            mark.isHidden = false
        } else {
            mark.isHidden = true
        }
        chevron.isHidden = !drillIn
        chevronWidth.constant = drillIn ? 10 : 0
        tick(now: now)
        accessibilityLabel = "\(child.goal), \(SubagentLook.word(child.status))"
        accessibilityValue = line
        accessibilityHint = drillIn ? "Opens its steps" : nil
        accessibilityTraits = picked ? [.button, .selected] : .button
    }

    func tick(now: Double) {
        guard let child else { return }
        let text = SubagentRules.formatElapsed(SubagentLook.elapsed(child, now: now))
        if timer.text != text { timer.text = text }
    }
}

/// "‹ All helpers · 2 running" at the top of a helper's page on the phone.
final class SubagentBackRow: ShelfRowControl {
    private let icon = UIImageView(image: SubagentLook.image("chevron.left", size: 13))
    private let words = ShelfText.label(ShelfText.footnoteBold, color: ChatPalette.tint, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = HQShape.radius(12, .card)
        layer.cornerCurve = .continuous
        icon.tintColor = ChatPalette.tint
        for v: UIView in [icon, words] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            words.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "chat.subagent.back"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(count: Int, live: Int) {
        let text = count == 1 ? "All Helpers" : "All \(count) Helpers"
        if words.text != text { words.text = text }
        accessibilityLabel = text
        accessibilityValue = live > 0 ? "\(live) running" : "All finished"
    }
}

// MARK: - A helper's page

/// The page: goal and status, result, steps, files, output, then the Steer row while it runs.
final class SubagentDetailView: UIView {
    let field = UITextField()
    let send = UIButton(type: .custom)
    let stop = UIButton(type: .custom)
    let outputToggle = UIButton(type: .system)
    private let goal = ShelfText.label(ShelfText.subheadline)
    private let status = ShelfText.label(ShelfText.footnote, lines: ShelfText.isLarge ? 0 : 1)
    private let timer = UILabel()
    private let resultBox = UIView()
    private let resultText = ShelfText.label(ShelfText.footnote)
    private let stepsHeader = SubagentDetailView.header("Steps")
    private let steps = UIStackView()
    private let filesHeader = SubagentDetailView.header("Files")
    private let files = UIStackView()
    private let outputHeader = SubagentDetailView.header("Output")
    private let outputBox = UIView()
    private let output = ShelfText.label(HQFont.mono(12.5, like: .footnote, cap: 22))
    private let truncatedNote = ShelfText.label(ShelfText.caption, color: ChatPalette.label2)
    private let steerRow = UIStackView()
    private let feedback = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private var busy = false
    private var child: SubagentProgress?
    /// Output folded to its last lines.
    static let foldedOutputLines = 12

    private static func header(_ text: String) -> UILabel {
        let l = ShelfText.label(ShelfText.footnoteBold, color: ChatPalette.label2, lines: 1)
        l.text = text
        l.accessibilityTraits = .header
        return l
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        // Goal, then "● Running · model · 3 tools · 1.2k tok" with the running time on the right.
        goal.font = HQFont.face(ofSize: ShelfText.subheadline.pointSize, weight: .semibold)
        goal.accessibilityTraits = .header
        status.lineBreakMode = .byTruncatingTail
        timer.font = HQFont.monoDigitFace(ofSize: ShelfText.footnote.pointSize, weight: .regular)
        timer.textColor = ChatPalette.label2
        timer.setContentHuggingPriority(.required, for: .horizontal)
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [status, timer])
        statusRow.spacing = 8
        statusRow.alignment = .firstBaseline
        column.addArrangedSubview(goal)
        column.addArrangedSubview(statusRow)
        column.setCustomSpacing(12, after: statusRow)
        // The result, once it finished.
        resultBox.backgroundColor = ChatPalette.fill4
        resultBox.layer.cornerRadius = 10
        resultBox.layer.cornerCurve = .continuous
        resultText.translatesAutoresizingMaskIntoConstraints = false
        resultBox.addSubview(resultText)
        NSLayoutConstraint.activate([
            resultText.topAnchor.constraint(equalTo: resultBox.topAnchor, constant: 10),
            resultText.leadingAnchor.constraint(equalTo: resultBox.leadingAnchor, constant: 12),
            resultText.trailingAnchor.constraint(equalTo: resultBox.trailingAnchor, constant: -12),
            resultText.bottomAnchor.constraint(equalTo: resultBox.bottomAnchor, constant: -10),
        ])
        column.addArrangedSubview(resultBox)
        column.setCustomSpacing(14, after: resultBox)
        // Steps, files, output.
        steps.axis = .vertical
        steps.spacing = 0
        files.axis = .vertical
        files.spacing = 0
        for (header, body) in [(stepsHeader, steps as UIView), (filesHeader, files)] {
            column.addArrangedSubview(header)
            column.setCustomSpacing(2, after: header)
            column.addArrangedSubview(body)
            column.setCustomSpacing(14, after: body)
        }
        outputBox.backgroundColor = ChatPalette.fill4
        outputBox.layer.cornerRadius = 10
        outputBox.layer.cornerCurve = .continuous
        output.translatesAutoresizingMaskIntoConstraints = false
        outputBox.addSubview(output)
        NSLayoutConstraint.activate([
            output.topAnchor.constraint(equalTo: outputBox.topAnchor, constant: 10),
            output.leadingAnchor.constraint(equalTo: outputBox.leadingAnchor, constant: 12),
            output.trailingAnchor.constraint(equalTo: outputBox.trailingAnchor, constant: -12),
            output.bottomAnchor.constraint(equalTo: outputBox.bottomAnchor, constant: -10),
        ])
        output.lineBreakMode = .byCharWrapping
        outputToggle.titleLabel?.font = ShelfText.footnoteBold
        outputToggle.titleLabel?.adjustsFontForContentSizeCategory = true
        outputToggle.contentHorizontalAlignment = .leading
        outputToggle.tintColor = ChatPalette.tint
        outputToggle.accessibilityIdentifier = "chat.subagent.output-toggle"
        outputToggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        truncatedNote.text = "Showing the latest 16 KB"
        let outputColumn = UIStackView(arrangedSubviews: [outputHeader, truncatedNote, outputBox, outputToggle])
        outputColumn.axis = .vertical
        outputColumn.spacing = 4
        outputColumn.setCustomSpacing(6, after: truncatedNote)
        column.addArrangedSubview(outputColumn)
        column.setCustomSpacing(12, after: outputColumn)
        // The Steer box (owner, 2026-10-29: the old grey capsule with ↑ and ■ beside it "looks pretty lame"): one
        // composer-style box, a steer mark at its start, the round ↑ inside its end; its outline takes the tint while you
        // type. Stop is a small red pill on the status line, out of the way of Send.
        field.placeholder = "Steer this helper…"
        field.font = HQFont.preferred(.body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ChatPalette.label
        field.tintColor = ChatPalette.tint
        field.backgroundColor = ChatPalette.fill4
        field.layer.cornerRadius = 22
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1
        field.clearButtonMode = .never
        let steerMark = UIImageView(image: SubagentLook.image("arrow.turn.down.right", size: HQFont.symbolSize(13, like: .body, cap: 20)))
        steerMark.tintColor = ChatPalette.label2
        steerMark.contentMode = .center
        steerMark.frame = CGRect(x: 0, y: 0, width: 40, height: 44)
        let leading = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 44))
        leading.addSubview(steerMark)
        field.leftView = leading
        field.leftViewMode = .always
        let trailing = UIView(frame: CGRect(x: 0, y: 0, width: 46, height: 44))
        send.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
        trailing.addSubview(send)
        field.rightView = trailing
        field.rightViewMode = .always
        field.returnKeyType = .send
        field.accessibilityLabel = "Steer this helper…"
        field.accessibilityIdentifier = "chat.subagent.steer-field"
        field.addAction(UIAction { [weak self] _ in self?.refreshFocus() }, for: [.editingDidBegin, .editingDidEnd])
        send.layer.cornerRadius = 16
        send.setImage(SubagentLook.image("arrow.up", size: 14, weight: .bold), for: .normal)
        send.accessibilityLabel = "Steer"
        send.accessibilityIdentifier = "chat.subagent.steer"
        var stopLook = UIButton.Configuration.tinted()
        stopLook.baseForegroundColor = ChatPalette.red
        stopLook.baseBackgroundColor = ChatPalette.red
        stopLook.image = SubagentLook.image("stop.fill", size: 9, weight: .bold)
        stopLook.imagePadding = 5
        stopLook.title = "Stop"
        stopLook.cornerStyle = .capsule
        stopLook.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 11)
        stopLook.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = ShelfText.footnoteBold; return a
        }
        stop.configuration = stopLook
        stop.accessibilityLabel = "Stop"
        stop.accessibilityIdentifier = "chat.subagent.stop"
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusRow.addArrangedSubview(stop)
        statusRow.alignment = .center
        steerRow.addArrangedSubview(field)
        steerRow.axis = .horizontal
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        refreshFocus()
        // Right under the status, in reach while it runs (at the foot it went out of sight in the capped card).
        let at = column.arrangedSubviews.firstIndex(of: statusRow)! + 1
        column.insertArrangedSubview(steerRow, at: at)
        feedback.accessibilityIdentifier = "chat.subagent.feedback"
        column.insertArrangedSubview(feedback, at: at + 1)
        column.setCustomSpacing(8, after: statusRow)
        column.setCustomSpacing(12, after: steerRow)
        column.setCustomSpacing(12, after: feedback)
        refreshSend()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refreshSend() {
        let hasText = !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = hasText && !busy
        send.backgroundColor = hasText ? ChatPalette.tint : ChatPalette.fill3
        send.tintColor = hasText ? ChatPalette.onTint : ChatPalette.label2
        stop.isEnabled = !busy
    }

    /// The Desktop Look's flat 4 pt corners (its panels and composer); the round shapes otherwise.
    private func applyLook() {
        let flat = Theme.isDesktop
        field.layer.cornerRadius = flat ? 4 : 22
        resultBox.layer.cornerRadius = flat ? 4 : 10
        outputBox.layer.cornerRadius = flat ? 4 : 10
        if var c = stop.configuration {
            let style: UIButton.Configuration.CornerStyle = flat ? .fixed : .capsule
            if c.cornerStyle != style {
                c.cornerStyle = style
                c.background.cornerRadius = 4
                stop.configuration = c
            }
        }
    }

    /// The box's outline: the tint while you type, a hairline otherwise.
    private func refreshFocus() {
        field.layer.borderColor = (field.isFirstResponder ? ChatPalette.tint : ChatPalette.separator).resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshFocus()
    }

    func update(_ child: SubagentProgress, tail: SubagentTail?, draft: String, feedback text: SubagentsBody.Feedback?,
                busy: Bool, expanded: Bool, now: Double) {
        self.child = child
        self.busy = busy
        applyLook()
        if !field.isFirstResponder, field.text != draft { field.text = draft }
        refreshSend()
        if goal.text != child.goal { goal.text = child.goal }
        status.attributedText = statusLine(child)
        tick(now: now)
        // Result.
        let summary = child.isLive ? nil : child.summary.flatMap { $0.isEmpty ? nil : $0 }
        resultBox.isHidden = summary == nil
        if let summary, resultText.text != summary { resultText.text = summary }
        // Steps: the last 12, newest at the bottom (the newest in the text colour, the rest a step back).
        // (The summary line is the result box once it finished: not a step as well.)
        let stream = summary == nil ? child.stream : child.stream.filter { $0.kind != .summary }
        let entries = Array(stream.suffix(12))
        syncRows(steps, count: entries.count) { SubagentStepRow() }
        for (i, entry) in entries.enumerated() {
            (steps.arrangedSubviews[i] as? SubagentStepRow)?.update(entry, newest: i == entries.count - 1 && child.isLive,
                                                                      offset: Int(entry.at - child.startedAt))
        }
        stepsHeader.text = stream.count > entries.count ? "Steps · latest \(entries.count) of \(stream.count)" : "Steps"
        stepsHeader.isHidden = entries.isEmpty
        steps.isHidden = entries.isEmpty
        // Files: written first, up to 8.
        let all = child.filesWritten.map { ($0, true) } + child.filesRead.map { ($0, false) }
        let shownFiles = Array(all.prefix(8))
        syncRows(files, count: shownFiles.count) { SubagentFileRow() }
        for (i, f) in shownFiles.enumerated() { (files.arrangedSubviews[i] as? SubagentFileRow)?.update(path: f.0, written: f.1) }
        filesHeader.text = all.count > shownFiles.count ? "Files · \(all.count)" : "Files"
        filesHeader.isHidden = all.isEmpty
        files.isHidden = all.isEmpty
        // Output: only once a tail answered with text; folded to its last lines.
        let tailText = (tail?.available == true) ? (tail?.text ?? "") : ""
        let outputShown = !tailText.isEmpty
        outputHeader.superview?.isHidden = !outputShown
        if outputShown {
            let lines = tailText.split(separator: "\n", omittingEmptySubsequences: false)
            let folds = lines.count > Self.foldedOutputLines
            let text = folds && !expanded ? lines.suffix(Self.foldedOutputLines).joined(separator: "\n") : tailText
            if output.text != text { output.text = text }
            truncatedNote.isHidden = tail?.truncated != true
            outputToggle.isHidden = !folds
            outputToggle.setTitle(expanded ? "Show Less" : "Show All \(lines.count) Lines", for: .normal)
        }
        // Steer while it runs (or while words you typed to it are still in the field). An empty field lets go when it
        // ends, so the keyboard goes down with it.
        if !child.isLive, draft.isEmpty, field.isFirstResponder { field.resignFirstResponder() }
        steerRow.isHidden = !(child.isLive || !draft.isEmpty || field.isFirstResponder)
        stop.isHidden = !child.isLive
        feedback.isHidden = text == nil
        feedback.text = text?.text
        feedback.textColor = text?.isError == true ? ChatPalette.red : ChatPalette.label2
    }

    func tick(now: Double) {
        guard let child else { return }
        let text = SubagentRules.formatElapsed(SubagentLook.elapsed(child, now: now))
        if timer.text != text { timer.text = text }
    }

    private func statusLine(_ child: SubagentProgress) -> NSAttributedString {
        let color = SubagentLook.color(child.status)
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: ShelfText.footnote])
        s.append(NSAttributedString(string: SubagentLook.word(child.status),
                                    attributes: [.foregroundColor: ChatPalette.label, .font: ShelfText.footnoteBold]))
        let tokens = (child.inputTokens ?? 0) + (child.outputTokens ?? 0)
        let tools = child.toolCount ?? 0
        let parts = [child.model ?? "",
                     tools > 0 ? (tools == 1 ? "1 tool" : "\(ActivityJSON.jsNumber(tools)) tools") : "",
                     tokens > 0 ? "\(SubagentRules.compactNumber(tokens)) tok" : ""].filter { !$0.isEmpty }
        if !parts.isEmpty {
            s.append(NSAttributedString(string: " · " + parts.joined(separator: " · "),
                                        attributes: [.foregroundColor: ChatPalette.label2, .font: ShelfText.footnote]))
        }
        return s
    }

    private func syncRows<V: UIView>(_ stack: UIStackView, count: Int, make: () -> V) {
        while stack.arrangedSubviews.count > count {
            let v = stack.arrangedSubviews.last!
            stack.removeArrangedSubview(v); v.removeFromSuperview()
        }
        while stack.arrangedSubviews.count < count { stack.addArrangedSubview(make()) }
    }
}

/// One step on the timeline: its mark, the line (2 lines), and when it came (time since the helper started).
final class SubagentStepRow: UIView {
    private let icon = UIImageView()
    private let text = ShelfText.label(ShelfText.footnote, lines: 2)
    private let time = UILabel()
    private let rail = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .center
        text.lineBreakMode = .byTruncatingTail
        time.font = HQFont.monoDigitFace(ofSize: ShelfText.caption.pointSize, weight: .regular)
        time.textColor = ChatPalette.label2
        time.textAlignment = .right
        rail.backgroundColor = ChatPalette.separator
        for v: UIView in [rail, icon, text, time] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let timeW = ceil(("00:00" as NSString).size(withAttributes: [.font: time.font!]).width)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -ShelfText.footnote.capHeight / 2),
            rail.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            rail.widthAnchor.constraint(equalToConstant: 1),
            rail.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            text.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -8),
            time.trailingAnchor.constraint(equalTo: trailingAnchor),
            time.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            time.widthAnchor.constraint(equalToConstant: timeW),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ entry: SubagentStreamEntry, newest: Bool, offset: Int) {
        icon.image = SubagentLook.image(SubagentLook.symbol(entry), size: HQFont.symbolSize(11, like: .footnote, cap: 18))
        icon.tintColor = entry.isError ? ChatPalette.red : newest ? GlyphFrames.purple : ChatPalette.label2
        if text.text != entry.text { text.text = entry.text }
        text.textColor = entry.isError ? ChatPalette.red : newest ? ChatPalette.label : ChatPalette.label2
        let t = SubagentRules.formatElapsed(offset)
        if time.text != t { time.text = t }
        accessibilityLabel = entry.text
        accessibilityValue = "at \(t)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The rail joins this step to the next one; the last step has none.
        rail.isHidden = superview?.subviews.last === self
    }
}

/// A file the helper touched: ✎ written or 📄 read · name · its folder.
final class SubagentFileRow: UIView {
    private let icon = UIImageView()
    private let text = ShelfText.label(ShelfText.footnote, lines: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .center
        icon.tintColor = ChatPalette.label2
        text.lineBreakMode = .byTruncatingMiddle
        for v: UIView in [icon, text] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(path: String, written: Bool) {
        icon.image = SubagentLook.image(written ? "pencil" : "doc.text", size: HQFont.symbolSize(11, like: .footnote, cap: 18))
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        let s = NSMutableAttributedString(string: name, attributes: [.font: ShelfText.footnoteBold, .foregroundColor: ChatPalette.label])
        if !folder.isEmpty {
            s.append(NSAttributedString(string: "  " + folder, attributes: [.font: ShelfText.footnote, .foregroundColor: ChatPalette.label2]))
        }
        text.attributedText = s
        accessibilityLabel = "\(written ? "Wrote" : "Read") \(path)"
    }
}
