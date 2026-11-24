import UIKit

// [background] The Background tasks card on the chat's shelf (owner 2026-11-15: "Shouldn't that background work be shown
// the same as subagents do?"). Opened, it lists each running job with its purpose, clean runner/folder detail, live
// ticking elapsed time, a multi-line preview of its newest output, and ⋯ actions; tapping any row drills into the job's
// detail page (full headline, status, Stop, metadata, live multi-line output, folder, and full command) — inline above
// the composer, and side by side on wide screens (Mac, iPad), matching SubagentsBody. Read from `process.list`
// (`ChatActivityController.backgroundPoll`).

/// Client-side timing for one running job so elapsed time and output freshness tick smoothly between 5 s polls.
struct BackgroundTaskTiming: Equatable {
    /// Wall-clock timestamp when `uptimeSeconds` was last read from `process.list`.
    var observedAt: Double
    /// Wall-clock timestamp when output last changed (from gateway `last_output_at`, or observed locally across polls).
    var outputChangedAt: Double?
}

final class BackgroundTasksBody: UIView, ShelfMeasuredBody {
    private var revision = ShelfRevision()
    var layoutRevision: Int { revision.value }
    /// A row was tapped (its id), or Back returned to the list (nil).
    var onSelect: ((String?) -> Void)?
    /// Stop was chosen for this command (its id).
    var onStop: ((String) -> Void)?

    /// The card is wide enough for the list and detail page side by side (same threshold as SubagentsBody).
    static let wideWidth: CGFloat = 600

    private let stack = UIStackView()
    private let list = UIStackView()
    private let back = BackgroundBackRow()
    private let split = UIStackView()
    private let divider = UIView()
    private let pageColumn = UIStackView()
    private let placeholder = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private var rows: [String: BackgroundTaskRow] = [:]
    private let detail = BackgroundTaskDetailView()
    private var selected: String?
    private var wide = false
    /// Jobs whose full output or full command is expanded in the detail view.
    private var expandedOutput: Set<String> = []
    private var expandedCommand: Set<String> = []
    private var listWidth: NSLayoutConstraint?
    private var dividerHeight: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        list.axis = .vertical
        list.spacing = 2
        split.axis = .horizontal
        split.alignment = .top
        split.spacing = 10
        divider.backgroundColor = ChatPalette.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let dividerWidth = divider.widthAnchor.constraint(equalToConstant: HQShape.pixel(traitCollection.displayScale))
        dividerWidth.isActive = true
        registerForTraitChanges([UITraitDisplayScale.self]) { (body: BackgroundTasksBody, _) in
            dividerWidth.constant = HQShape.pixel(body.traitCollection.displayScale)
        }
        pageColumn.axis = .vertical
        placeholder.text = "Choose a background task to see its output."
        placeholder.textAlignment = .center
        back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        detail.stop.addTarget(self, action: #selector(detailStopTapped), for: .touchUpInside)
        detail.outputToggle.addTarget(self, action: #selector(outputToggled), for: .touchUpInside)
        detail.commandToggle.addTarget(self, action: #selector(commandToggled), for: .touchUpInside)
        accessibilityIdentifier = "chat.background.list"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `stopping`: ids whose Stop went out (their row and detail say "Stopping…").
    func update(_ commands: [BackgroundProcess], selected: String?, stopping: Set<String>,
                timing: [String: BackgroundTaskTiming], wide: Bool, width: CGFloat, now: Double) {
        let ids = commands.map(\.id)
        let sel = selected.flatMap { ids.contains($0) ? $0 : nil }
        let outExpanded = sel.map { expandedOutput.contains($0) } ?? false
        let cmdExpanded = sel.map { expandedCommand.contains($0) } ?? false
        var h = Hasher()
        for c in commands {
            h.combine(c.id); h.combine(c.headline); h.combine(c.fullHeadline); h.combine(c.detailLine)
            h.combine(c.cleanedTail); h.combine(c.botNote); h.combine(c.cwd)
            h.combine(c.effectiveCommand); h.combine(c.watchPatterns); h.combine(c.watchHit)
            h.combine(c.pid); h.combine(c.startedAt); h.combine(stopping.contains(c.id))
            h.combine(timing[c.id]?.outputChangedAt != nil)
        }
        h.combine(sel); h.combine(wide); h.combine(outExpanded); h.combine(cmdExpanded)
        revision.note(h.finalize())
        self.selected = sel
        self.wide = wide

        for (id, row) in rows where !ids.contains(id) { row.removeFromSuperview(); rows[id] = nil }
        expandedOutput.formIntersection(ids)
        expandedCommand.formIntersection(ids)
        for command in commands {
            let row = rows[command.id] ?? {
                let r = BackgroundTaskRow()
                r.onStop = { [weak self] id in self?.onStop?(id) }
                r.onOpen = { [weak self] id in self?.openRow(id) }
                r.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                rows[command.id] = r
                return r
            }()
            row.update(command, stopping: stopping.contains(command.id), timing: timing[command.id],
                       picked: wide && command.id == sel, drillIn: !wide, now: now)
        }
        let wantedRows: [UIView] = ids.compactMap { rows[$0] }
        if list.arrangedSubviews != wantedRows { arrange(list, wantedRows) }

        let wantedStack: [UIView]
        if wide {
            let page: UIView = sel == nil ? placeholder : detail
            if pageColumn.arrangedSubviews != [page] { arrange(pageColumn, [page]) }
            if split.arrangedSubviews != [list, divider, pageColumn] { arrange(split, [list, divider, pageColumn]) }
            let w = min(300, max(230, (width * 0.38).rounded()))
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
            wantedStack = sel == nil ? [list] : [back, detail]
        }
        if stack.arrangedSubviews != wantedStack { arrange(stack, wantedStack) }
        back.set(count: commands.count)
        if let sel, let command = commands.first(where: { $0.id == sel }) {
            detail.update(command, stopping: stopping.contains(sel), timing: timing[sel],
                          outputExpanded: outExpanded, commandExpanded: cmdExpanded, now: now)
        }
    }

    private func arrange(_ s: UIStackView, _ views: [UIView]) {
        for v in s.arrangedSubviews where !views.contains(v) { s.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, v) in views.enumerated() where s.arrangedSubviews.firstIndex(of: v) != i { s.insertArrangedSubview(v, at: i) }
    }

    /// Ticks elapsed timers and freshness readouts without triggering layout passes.
    func tick(now: Double) {
        rows.values.forEach { $0.tick(now: now) }
        if selected != nil { detail.tick(now: now) }
    }

    /// What a tap opened, in `view`'s coordinates: the detail's back row (phone), or the picked row (wide).
    func selectedFrame(in view: UIView) -> CGRect? {
        guard let sel = selected else { return nil }
        if wide, let row = rows[sel], row.window != nil { return row.convert(row.bounds, to: view) }
        guard back.window != nil else { return nil }
        return back.convert(back.bounds, to: view)
    }

    private func openRow(_ id: String) {
        Haptics.play(.selection)
        if wide, selected == id { return }
        onSelect?(id)
    }

    @objc private func rowTapped(_ sender: BackgroundTaskRow) {
        guard let id = rows.first(where: { $0.value === sender })?.key else { return }
        openRow(id)
    }

    @objc private func backTapped() {
        Haptics.play(.selection)
        onSelect?(nil)
    }

    @objc private func detailStopTapped() {
        guard let id = selected else { return }
        Haptics.play(.rigid)
        onStop?(id)
    }

    @objc private func outputToggled() {
        guard let id = selected else { return }
        Haptics.play(.selection)
        if expandedOutput.contains(id) { expandedOutput.remove(id) } else { expandedOutput.insert(id) }
        onSelect?(id)
    }

    @objc private func commandToggled() {
        guard let id = selected else { return }
        Haptics.play(.selection)
        if expandedCommand.contains(id) { expandedCommand.remove(id) } else { expandedCommand.insert(id) }
        onSelect?(id)
    }
}

// MARK: - List row

/// One running job in the list: spinner · purpose (2 lines) · live time · › · ⋯; runner/folder (+ freshness when
/// observed); and either a subtle multi-line output preview box or an honest quiet line. Tap opens its detail page.
final class BackgroundTaskRow: ShelfRowControl {
    var onStop: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    private let spinner = GlyphSpinner(style: .braille, color: ChatPalette.label2, size: HQFont.symbolSize(15, like: .subheadline, cap: 24))
    private let title = ShelfText.label(ShelfText.footnoteBold, lines: 2)
    private let detail = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 1)
    private let outputBox = UIView()
    private let outputStack = UIStackView()
    private let earlierOutput = ShelfText.label(ShelfText.caption, color: ChatPalette.label2, lines: 2)
    private let subtitle = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2, lines: 2)
    private var outputUnderTitle: NSLayoutConstraint!
    private var outputUnderDetail: NSLayoutConstraint!
    private var outputClearMore: NSLayoutConstraint!
    private var outputTrailingEdge: NSLayoutConstraint!
    private var outputTrailingMore: NSLayoutConstraint!
    private var boxInsets: [NSLayoutConstraint] = []
    private let timer = UILabel()
    private let chevron = UIImageView(image: SubagentLook.image("chevron.right", size: 12))
    private var chevronWidth: NSLayoutConstraint!
    private let more = UIButton(type: .system)
    private var command: BackgroundProcess?
    private var timing: BackgroundTaskTiming?
    private var picked = false
    private var baseDetail: String?

    override var isHighlighted: Bool {
        didSet { backgroundColor = (isHighlighted && !DeviceWord.isMac) || picked ? ChatPalette.fill4 : .clear }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        title.lineBreakMode = .byTruncatingTail
        title.accessibilityIdentifier = "chat.background.title"
        title.isUserInteractionEnabled = false
        detail.lineBreakMode = .byTruncatingMiddle
        detail.accessibilityIdentifier = "chat.background.detail"
        detail.isUserInteractionEnabled = false
        let mono = HQFont.monoFace(ofSize: ShelfText.caption.pointSize, weight: .regular)
        earlierOutput.font = mono
        earlierOutput.lineBreakMode = .byTruncatingTail
        earlierOutput.isUserInteractionEnabled = false
        subtitle.font = mono
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.accessibilityIdentifier = "chat.background.output"
        subtitle.isUserInteractionEnabled = false
        outputBox.layer.cornerCurve = .continuous
        outputBox.isUserInteractionEnabled = false
        outputStack.axis = .vertical
        outputStack.spacing = 2
        outputStack.isUserInteractionEnabled = false
        outputStack.translatesAutoresizingMaskIntoConstraints = false
        outputStack.addArrangedSubview(earlierOutput)
        outputStack.addArrangedSubview(subtitle)
        outputBox.addSubview(outputStack)
        let top = outputStack.topAnchor.constraint(equalTo: outputBox.topAnchor)
        let leading = outputStack.leadingAnchor.constraint(equalTo: outputBox.leadingAnchor)
        let trailing = outputStack.trailingAnchor.constraint(equalTo: outputBox.trailingAnchor)
        let bottom = outputStack.bottomAnchor.constraint(equalTo: outputBox.bottomAnchor)
        boxInsets = [top, leading, trailing, bottom]
        NSLayoutConstraint.activate(boxInsets)

        timer.font = HQFont.monoDigitFace(ofSize: ShelfText.footnote.pointSize, weight: .regular)
        timer.textColor = ChatPalette.label2
        timer.textAlignment = .right
        timer.isUserInteractionEnabled = false
        timer.setContentHuggingPriority(.required, for: .horizontal)
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.tintColor = ChatPalette.label2
        chevron.contentMode = .center
        chevron.isUserInteractionEnabled = false
        more.setImage(SubagentLook.image("ellipsis.circle", size: HQFont.symbolSize(17, like: .subheadline, cap: 26), weight: .regular), for: .normal)
        more.tintColor = ChatPalette.label2
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "Task Actions"
        more.accessibilityIdentifier = "chat.background.more"
        for v: UIView in [spinner, title, detail, outputBox, timer, chevron, more] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        spinner.isUserInteractionEnabled = false
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 10)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: timer.leadingAnchor, constant: -8),
            timer.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            timer.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -5),
            chevron.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -ShelfText.footnote.capHeight / 2),
            chevron.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -2),
            chevronWidth,
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            more.widthAnchor.constraint(equalToConstant: 44),
            more.heightAnchor.constraint(equalToConstant: 44),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            outputBox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            outputBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        outputUnderTitle = outputBox.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5)
        outputUnderDetail = outputBox.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 5)
        outputClearMore = outputBox.topAnchor.constraint(greaterThanOrEqualTo: more.bottomAnchor, constant: 2)
        outputTrailingEdge = outputBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        outputTrailingMore = outputBox.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4)
        outputUnderTitle.isActive = true
        outputTrailingMore.isActive = true
        accessibilityIdentifier = "chat.background.row"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ command: BackgroundProcess, stopping: Bool, timing: BackgroundTaskTiming?,
                picked: Bool, drillIn: Bool, now: Double) {
        self.command = command
        self.timing = timing
        self.picked = picked
        layer.cornerRadius = Theme.isDesktop ? 4 : 12
        backgroundColor = picked ? ChatPalette.fill4 : .clear
        let name = command.headline
        if title.text != name { title.text = name }
        title.numberOfLines = ShelfText.isLarge ? 0 : 2

        baseDetail = command.detailLine
        let detailText = composedDetail(now: now)
        if detail.text != detailText { detail.text = detailText }
        let hasDetail = detailText != nil
        detail.isHidden = !hasDetail
        outputUnderTitle.isActive = !hasDetail
        outputUnderDetail.isActive = hasDetail

        let hasOutput = !stopping && !command.lastLine.isEmpty
        let line = stopping ? "Stopping…" : command.statusLine
        if subtitle.text != line { subtitle.text = line }
        subtitle.textColor = hasOutput ? ChatPalette.label : ChatPalette.label2
        subtitle.numberOfLines = ShelfText.isLarge ? 0 : 2
        let earlier = hasOutput ? command.earlierPreviewLines.joined(separator: "\n") : ""
        earlierOutput.isHidden = earlier.isEmpty
        if earlierOutput.text != earlier { earlierOutput.text = earlier }
        outputBox.backgroundColor = hasOutput ? ChatPalette.fill4 : .clear
        outputBox.layer.cornerRadius = Theme.isDesktop ? 4 : 8
        outputTrailingMore.isActive = !hasOutput
        outputTrailingEdge.isActive = hasOutput
        outputClearMore.isActive = hasOutput
        let vPad: CGFloat = hasOutput ? 6 : 0
        let hPad: CGFloat = hasOutput ? 8 : 0
        boxInsets[0].constant = vPad
        boxInsets[1].constant = hPad
        boxInsets[2].constant = -hPad
        boxInsets[3].constant = -vPad

        chevron.isHidden = !drillIn
        chevronWidth.constant = drillIn ? 10 : 0
        spinner.isHidden = stopping
        more.isEnabled = !stopping

        let id = command.id
        var items: [UIAction] = [
            UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.onOpen?(id)
            },
        ]
        if !command.cleanedTail.isEmpty {
            let output = command.cleanedTail
            items.append(UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = output
                Haptics.play(.success)
                HQAnnounce.say("Output copied to clipboard")
            })
        }
        let fullCommand = command.effectiveCommand
        items.append(UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { _ in
            UIPasteboard.general.string = fullCommand
            Haptics.play(.success)
            HQAnnounce.say("Command copied to clipboard")
        })
        items.append(UIAction(title: "Stop Task", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { [weak self] _ in
            self?.onStop?(id)
        })
        more.menu = UIMenu(children: items)

        tick(now: now)
        title.accessibilityTraits = .button
        title.accessibilityHint = drillIn ? "Opens task details" : nil
        subtitle.accessibilityLabel = line
    }

    func tick(now: Double) {
        guard let command else { return }
        let time = command.elapsedSeconds(observedAt: timing?.observedAt, now: now).map(BackgroundProcess.duration) ?? ""
        if timer.text != time { timer.text = time }
        let detailText = composedDetail(now: now)
        if detail.text != detailText { detail.text = detailText }
        title.accessibilityLabel = "\(command.headline), running" + (time.isEmpty ? "" : " for \(time)")
    }

    private func composedDetail(now: Double) -> String? {
        var parts: [String] = []
        if let baseDetail, !baseDetail.isEmpty { parts.append(baseDetail) }
        if let changed = timing?.outputChangedAt {
            parts.append(BackgroundProcess.freshnessWords(since: changed, now: now))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Back row

/// "‹ All Background Tasks" at the top of a job's detail page on the phone.
final class BackgroundBackRow: ShelfRowControl {
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
        accessibilityIdentifier = "chat.background.back"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(count: Int) {
        let text = count == 1 ? "All Background Tasks" : "All \(count) Background Tasks"
        if words.text != text { words.text = text }
        accessibilityLabel = text
    }
}

// MARK: - Detail page

/// One job's full page: untruncated headline, status + live timer + Stop, start/freshness/PID metadata,
/// optional bot context and watch patterns, live multi-line output with Copy & Show All, folder, and full command.
final class BackgroundTaskDetailView: UIView {
    let stop = UIButton(type: .custom)
    let outputToggle = UIButton(type: .system)
    let commandToggle = UIButton(type: .system)

    private let headline = ShelfText.label(ShelfText.subheadline)
    private let status = ShelfText.label(ShelfText.footnote, lines: ShelfText.isLarge ? 0 : 1)
    private let timer = UILabel()
    private let meta = ShelfText.label(ShelfText.caption, color: ChatPalette.label2)
    private let noteBox = UIView()
    private let noteText = ShelfText.label(ShelfText.footnote)
    private let watchSection = UIStackView()
    private let watchText = ShelfText.label(ShelfText.footnote, color: ChatPalette.label2)
    private let copyOutput = UIButton(type: .system)
    private let outputBox = UIView()
    private let outputLabel = ShelfText.label(HQFont.mono(12.5, like: .footnote, cap: 22))
    private let folderSection = UIStackView()
    private let folderLabel = ShelfText.label(HQFont.mono(12.5, like: .footnote, cap: 22), color: ChatPalette.label)
    private let commandSection = UIStackView()
    private let copyCommand = UIButton(type: .system)
    private let commandBox = UIView()
    private let commandLabel = ShelfText.label(HQFont.mono(12.5, like: .footnote, cap: 22))

    private var command: BackgroundProcess?
    private var timing: BackgroundTaskTiming?
    private var stopping = false

    static let foldedOutputLines = 12
    static let foldedCommandLines = 6

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func header(_ text: String) -> UILabel {
        let l = ShelfText.label(ShelfText.footnoteBold, color: ChatPalette.label2, lines: 1)
        l.text = text
        l.accessibilityTraits = .header
        return l
    }

    private static func copyButton(_ id: String, label: String) -> UIButton {
        let b = UIButton(type: .system)
        var c = UIButton.Configuration.plain()
        c.title = "Copy"
        c.baseForegroundColor = ChatPalette.tintText
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 2)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = ShelfText.footnoteBold; return a
        }
        b.configuration = c
        b.accessibilityLabel = label
        b.accessibilityIdentifier = id
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    private static func box(containing label: UILabel) -> UIView {
        let v = UIView()
        v.backgroundColor = ChatPalette.fill4
        v.layer.cornerRadius = 10
        v.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
        ])
        return v
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

        headline.font = HQFont.face(ofSize: ShelfText.subheadline.pointSize, weight: .semibold)
        headline.accessibilityTraits = .header
        headline.accessibilityIdentifier = "chat.background.detail.title"
        status.lineBreakMode = .byTruncatingTail
        timer.font = HQFont.monoDigitFace(ofSize: ShelfText.footnote.pointSize, weight: .regular)
        timer.textColor = ChatPalette.label2
        timer.setContentHuggingPriority(.required, for: .horizontal)
        timer.setContentCompressionResistancePriority(.required, for: .horizontal)

        var stopLook = UIButton.Configuration.tinted()
        stopLook.baseForegroundColor = ChatPalette.red
        stopLook.baseBackgroundColor = ChatPalette.red
        stopLook.image = SubagentLook.image("stop.fill", size: 9, weight: .bold)
        stopLook.imagePadding = 5
        stopLook.title = "Stop"
        stopLook.titleLineBreakMode = .byClipping
        stopLook.cornerStyle = .capsule
        stopLook.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 11)
        stopLook.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = ShelfText.footnoteBold; return a
        }
        stop.configuration = stopLook
        stop.accessibilityLabel = "Stop Task"
        stop.accessibilityIdentifier = "chat.background.detail.stop"
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)

        let statusRow = UIStackView(arrangedSubviews: [status, timer, stop])
        statusRow.spacing = 8
        statusRow.alignment = .center
        meta.accessibilityIdentifier = "chat.background.detail.meta"

        column.addArrangedSubview(headline)
        column.addArrangedSubview(statusRow)
        column.addArrangedSubview(meta)
        column.setCustomSpacing(12, after: meta)

        // Output section (first, right under the status/meta header so live output is visible without scrolling).
        copyOutput.configuration = Self.copyButton("chat.background.copy-output", label: "Copy Output").configuration
        copyOutput.accessibilityLabel = "Copy Output"
        copyOutput.accessibilityIdentifier = "chat.background.copy-output"
        copyOutput.setContentHuggingPriority(.required, for: .horizontal)
        copyOutput.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyOutput.addAction(UIAction { [weak self] _ in self?.copyOutputTapped() }, for: .touchUpInside)
        let outputHeaderRow = UIStackView(arrangedSubviews: [Self.header("Output"), copyOutput])
        outputHeaderRow.alignment = .center
        outputHeaderRow.spacing = 8

        outputLabel.lineBreakMode = .byCharWrapping
        outputLabel.accessibilityIdentifier = "chat.background.detail.output"
        let outBox = Self.box(containing: outputLabel)
        outputBox.addSubview(outBox)
        outBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outBox.topAnchor.constraint(equalTo: outputBox.topAnchor),
            outBox.leadingAnchor.constraint(equalTo: outputBox.leadingAnchor),
            outBox.trailingAnchor.constraint(equalTo: outputBox.trailingAnchor),
            outBox.bottomAnchor.constraint(equalTo: outputBox.bottomAnchor),
        ])
        for toggle in [outputToggle, commandToggle] {
            toggle.titleLabel?.font = ShelfText.footnoteBold
            toggle.titleLabel?.adjustsFontForContentSizeCategory = true
            toggle.contentHorizontalAlignment = .leading
            toggle.tintColor = ChatPalette.tintText
            toggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        }
        outputToggle.accessibilityIdentifier = "chat.background.output-toggle"
        let outputSection = UIStackView(arrangedSubviews: [outputHeaderRow, outputBox, outputToggle])
        outputSection.axis = .vertical
        outputSection.spacing = 4
        column.addArrangedSubview(outputSection)
        column.setCustomSpacing(12, after: outputSection)

        // Optional watch patterns.
        watchSection.axis = .vertical
        watchSection.spacing = 4
        watchSection.addArrangedSubview(Self.header("Watching"))
        watchSection.addArrangedSubview(watchText)
        column.addArrangedSubview(watchSection)
        column.setCustomSpacing(12, after: watchSection)

        // Optional bot context paragraph.
        noteBox.backgroundColor = ChatPalette.fill4
        noteBox.layer.cornerRadius = 10
        noteBox.layer.cornerCurve = .continuous
        noteText.translatesAutoresizingMaskIntoConstraints = false
        noteBox.addSubview(noteText)
        NSLayoutConstraint.activate([
            noteText.topAnchor.constraint(equalTo: noteBox.topAnchor, constant: 10),
            noteText.leadingAnchor.constraint(equalTo: noteBox.leadingAnchor, constant: 12),
            noteText.trailingAnchor.constraint(equalTo: noteBox.trailingAnchor, constant: -12),
            noteText.bottomAnchor.constraint(equalTo: noteBox.bottomAnchor, constant: -10),
        ])
        column.addArrangedSubview(noteBox)
        column.setCustomSpacing(12, after: noteBox)

        // Folder section.
        folderLabel.lineBreakMode = .byCharWrapping
        folderSection.axis = .vertical
        folderSection.spacing = 4
        folderSection.addArrangedSubview(Self.header("Folder"))
        folderSection.addArrangedSubview(folderLabel)
        column.addArrangedSubview(folderSection)
        column.setCustomSpacing(12, after: folderSection)

        // Command section.
        copyCommand.configuration = Self.copyButton("chat.background.copy-command", label: "Copy Command").configuration
        copyCommand.accessibilityLabel = "Copy Command"
        copyCommand.accessibilityIdentifier = "chat.background.copy-command"
        copyCommand.setContentHuggingPriority(.required, for: .horizontal)
        copyCommand.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyCommand.addAction(UIAction { [weak self] _ in self?.copyCommandTapped() }, for: .touchUpInside)
        let commandHeaderRow = UIStackView(arrangedSubviews: [Self.header("Command"), copyCommand])
        commandHeaderRow.alignment = .center
        commandHeaderRow.spacing = 8

        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.accessibilityIdentifier = "chat.background.detail.command"
        let cmdBox = Self.box(containing: commandLabel)
        commandBox.addSubview(cmdBox)
        cmdBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cmdBox.topAnchor.constraint(equalTo: commandBox.topAnchor),
            cmdBox.leadingAnchor.constraint(equalTo: commandBox.leadingAnchor),
            cmdBox.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor),
            cmdBox.bottomAnchor.constraint(equalTo: commandBox.bottomAnchor),
        ])
        commandToggle.accessibilityIdentifier = "chat.background.command-toggle"
        commandSection.axis = .vertical
        commandSection.spacing = 4
        commandSection.addArrangedSubview(commandHeaderRow)
        commandSection.addArrangedSubview(commandBox)
        commandSection.addArrangedSubview(commandToggle)
        column.addArrangedSubview(commandSection)
        accessibilityIdentifier = "chat.background.detail-view"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyLook() {
        let flat = Theme.isDesktop
        let radius: CGFloat = flat ? 4 : 10
        noteBox.layer.cornerRadius = radius
        outputBox.subviews.first?.layer.cornerRadius = radius
        commandBox.subviews.first?.layer.cornerRadius = radius
        if var c = stop.configuration {
            let style: UIButton.Configuration.CornerStyle = flat ? .fixed : .capsule
            if c.cornerStyle != style {
                c.cornerStyle = style
                c.background.cornerRadius = 4
                stop.configuration = c
            }
        }
    }

    func update(_ command: BackgroundProcess, stopping: Bool, timing: BackgroundTaskTiming?,
                outputExpanded: Bool, commandExpanded: Bool, now: Double) {
        self.command = command
        self.timing = timing
        self.stopping = stopping
        applyLook()

        if headline.text != command.fullHeadline { headline.text = command.fullHeadline }
        status.attributedText = statusLine(command, stopping: stopping)

        stop.isEnabled = !stopping
        if var c = stop.configuration {
            let wanted = stopping ? "Stopping…" : "Stop"
            if c.title != wanted { c.title = wanted; stop.configuration = c }
        }

        // Bot note.
        if let note = command.botNote, !note.isEmpty {
            noteBox.isHidden = false
            if noteText.text != note { noteText.text = note }
        } else {
            noteBox.isHidden = true
        }

        // Watch patterns.
        let watches = watchLine(command)
        watchSection.isHidden = watches == nil
        if let watches, watchText.text != watches { watchText.text = watches }

        // Live output.
        let cleaned = command.cleanedTail
        if cleaned.isEmpty {
            copyOutput.isHidden = true
            outputToggle.isHidden = true
            let quiet = stopping ? "Stopping…" : command.statusLine
            outputLabel.textColor = ChatPalette.label2
            if outputLabel.text != quiet { outputLabel.text = quiet }
        } else {
            copyOutput.isHidden = false
            outputLabel.textColor = ChatPalette.label
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            let folds = lines.count > Self.foldedOutputLines
            let shown = folds && !outputExpanded ? lines.suffix(Self.foldedOutputLines).joined(separator: "\n") : cleaned
            if outputLabel.text != shown { outputLabel.text = shown }
            outputToggle.isHidden = !folds
            outputToggle.setTitle(outputExpanded ? "Show Less" : "Show All \(lines.count) Lines", for: .normal)
        }

        // Folder.
        if let cwd = command.cwd, !cwd.isEmpty {
            folderSection.isHidden = false
            if folderLabel.text != cwd { folderLabel.text = cwd }
        } else {
            folderSection.isHidden = true
        }

        // Full command.
        let full = command.effectiveCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        commandSection.isHidden = full.isEmpty
        if !full.isEmpty {
            let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
            let folds = lines.count > Self.foldedCommandLines
            let shown = folds && !commandExpanded ? lines.prefix(Self.foldedCommandLines).joined(separator: "\n") : full
            if commandLabel.text != shown { commandLabel.text = shown }
            commandToggle.isHidden = !folds
            commandToggle.setTitle(commandExpanded ? "Show Less" : "Show Full Command (\(lines.count) Lines)", for: .normal)
        }

        tick(now: now)
    }

    func tick(now: Double) {
        guard let command else { return }
        let time = command.elapsedSeconds(observedAt: timing?.observedAt, now: now).map(BackgroundProcess.duration) ?? ""
        if timer.text != time { timer.text = time }
        let m = metaLine(command, now: now)
        meta.isHidden = m == nil
        if meta.text != m { meta.text = m }
    }

    private func statusLine(_ command: BackgroundProcess, stopping: Bool) -> NSAttributedString {
        let dotColor = stopping ? ChatPalette.orange : ChatPalette.green
        let word = stopping ? "Stopping…" : "Running"
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: dotColor, .font: ShelfText.footnote])
        s.append(NSAttributedString(string: word, attributes: [.foregroundColor: ChatPalette.label, .font: ShelfText.footnoteBold]))
        return s
    }

    private func metaLine(_ command: BackgroundProcess, now: Double) -> String? {
        var parts: [String] = []
        if let detail = command.detailLine, !detail.isEmpty {
            parts.append(detail)
        }
        if let start = command.startDate(observedAt: timing?.observedAt) {
            let today = Calendar.current.isDateInToday(start)
            let formatted = (today ? Self.timeFormatter : Self.dayTimeFormatter).string(from: start)
            parts.append("Started \(formatted)")
        }
        if let changed = timing?.outputChangedAt {
            parts.append(BackgroundProcess.freshnessWords(since: changed, now: now))
        }
        if let pid = command.pid {
            parts.append("PID \(pid)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func watchLine(_ command: BackgroundProcess) -> String? {
        var parts: [String] = []
        if !command.watchPatterns.isEmpty {
            parts.append(command.watchPatterns.joined(separator: " · "))
        }
        if let hit = command.watchHit {
            parts.append("Matched: \(hit)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func copyOutputTapped() {
        guard let text = command?.cleanedTail, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        Haptics.play(.success)
        HQAnnounce.say("Output copied to clipboard")
    }

    private func copyCommandTapped() {
        guard let text = command?.effectiveCommand, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        Haptics.play(.success)
        HQAnnounce.say("Command copied to clipboard")
    }
}
