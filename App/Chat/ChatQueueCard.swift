import UIKit

/// Messages sent while a reply runs wait in the chat's queue (spec 04 §6.2, M1: a local queue shown as a card, never as
/// transcript rows). This glass card above the composer lists them so a send never seems lost: each with Send Now
/// (steers it into the reply, or sends it now) and, in its ⋯ (or a tap on its words), Edit (its words change in place
/// in the composer, with Cancel and Save) and Delete (thrown away).
/// [m9/composer] The header is the web's ("Queue Paused · 2 Messages", `QueueWords`), with Resume while paused
/// (docs/spec/3x-composer.md §15.3, §16).
final class ChatQueueCard: UIView {
    var onSendNow: ((String) -> Void)?
    var onResume: (() -> Void)?
    /// Edit (spec §15.5): the screen puts the row's words in the composer with the edit strip.
    var onEdit: ((String) -> Void)?
    /// L463: Stop and Send (a reply runs), Delete (throw it away), and whether Send Now is offered for a row.
    var onStopAndSend: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var canSendNow: ((QueuedMessage) -> Bool)?
    /// Whether Edit is offered for a row (typed words only).
    var canEdit: ((QueuedMessage) -> Bool)?
    private var running = false
    private(set) var items: [QueuedMessage] = []
    /// Rows going out now ("Sending…"), and the row being edited ("Editing").
    private var sending: Set<String> = []
    private var editing: String?

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(20))
        return view
    }()
    private let header = UILabel()
    private lazy var resume: UIButton = {
        var config = UIButton.Configuration.hqGlass()   // [desktoplook3] outlined in the look
        config.title = "Resume"
        config.buttonSize = .small
        if !Theme.isDesktop { config.cornerStyle = .capsule }
        config.baseForegroundColor = ChatPalette.tint
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = HQFont.preferred(.subheadline)
            return out
        }
        let button = QueueRowButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.onResume?()
        })
        button.accessibilityLabel = "Resume queue"
        button.accessibilityIdentifier = "queue.resume"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true
        return button
    }()
    private let headerRow = UIStackView()
    private let stack = UIStackView()
    static let shownRows = 3
    /// At accessibility text sizes a row stacks: its words on top, Send Now and ⋯ under them.
    private var stacked: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        header.font = HQFont.preferred(.caption1)
        header.adjustsFontForContentSizeCategory = true
        header.textColor = ChatPalette.label2
        header.accessibilityIdentifier = "chat.queue.header"
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        headerRow.isLayoutMarginsRelativeArrangement = true
        headerRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6)
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(resume)
        // The row keeps one height with and without Resume, so the card does not jump when the queue pauses.
        headerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        stack.addArrangedSubview(headerRow)
        stack.setCustomSpacing(4, after: headerRow)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            {
                let top = stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8)
                top.priority = .init(999)
                return top
            }(),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
        ])
        // Collapsed to zero height while empty: the content gives way instead of fighting the collapse.
        let bottom = stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6)
        bottom.priority = .init(999)
        bottom.isActive = true
        // Collapsed, the rows are clipped by the glass's own content (never by this view: clipping here cut the glass's
        // shadow into a square box, verify round 1).
        glass.contentView.clipsToBounds = true
        accessibilityIdentifier = "chat.queue"
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (card: ChatQueueCard, previous: UITraitCollection) in
            guard previous.preferredContentSizeCategory.isAccessibilityCategory != card.stacked else { return }
            card.rebuildRows()
        }
        // The keyboard moves the card without resizing it: look at the opened rest's cap again (`layoutSubviews`).
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoved),
                                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func keyboardMoved() { if restHeight != nil { setNeedsLayout() } }

    /// Shows `items` (oldest first). Returns whether anything changed.
    @discardableResult
    func update(_ items: [QueuedMessage], parked: Bool, running: Bool, sending: Set<String> = [], editing: String? = nil) -> Bool {
        let headerText = QueueWords.header(count: items.count, paused: parked, running: running)
        let showResume = QueueWords.showsResume(count: items.count, paused: parked)
        guard items != self.items || header.text != headerText || resume.isHidden == showResume || running != self.running
                || sending != self.sending || editing != self.editing else { return false }
        self.running = running
        self.items = items
        self.sending = sending
        self.editing = editing
        header.text = headerText
        header.accessibilityLabel = QueueWords.spokenHeader(count: items.count, paused: parked, running: running)
        resume.isHidden = !showResume
        rebuildRows()
        return true
    }

    private func rebuildRows() {
        for view in stack.arrangedSubviews.dropFirst() { view.removeFromSuperview() }
        restHeight = nil
        if items.count <= Self.shownRows { expanded = false }
        for item in items.prefix(Self.shownRows) { stack.addArrangedSubview(row(item)) }
        guard items.count > Self.shownRows else { return }
        // The rest open in place under the first three (every one can then be sent, edited or deleted), scrolling
        // inside a capped height so the card never takes the chat.
        if expanded {
            let rest = UIStackView(arrangedSubviews: items.dropFirst(Self.shownRows).map { row($0) })
            rest.axis = .vertical
            rest.spacing = stack.spacing
            rest.translatesAutoresizingMaskIntoConstraints = false
            let scroll = UIScrollView()
            scroll.showsVerticalScrollIndicator = true
            scroll.addSubview(rest)
            let fit = scroll.heightAnchor.constraint(equalTo: rest.heightAnchor)
            fit.priority = .defaultHigh
            let cap = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: restCap)
            restHeight = cap
            NSLayoutConstraint.activate([
                rest.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                rest.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                rest.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
                rest.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
                fit,
                cap,
            ])
            stack.addArrangedSubview(scroll)
        }
        var config = UIButton.Configuration.plain()
        config.title = expanded ? "Show Less" : "Show \(items.count - Self.shownRows) More"
        config.baseForegroundColor = ChatPalette.tintText
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = HQFont.preferred(.subheadline)
            return out
        }
        let toggle = QueueRowButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.play(.selection)
            self.expanded.toggle()
            self.rebuildRows()
            self.onResize?()
        })
        toggle.contentHorizontalAlignment = .leading
        toggle.accessibilityIdentifier = "queue.showmore"
        toggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        stack.addArrangedSubview(toggle)
    }

    /// Show N More opened the rest of the queue in place.
    private var expanded = false
    /// The card's height changed by itself (Show More / Show Less): the screen lays the dock out again.
    var onResize: (() -> Void)?
    /// The opened rest's height cap, kept to `restCap` as the screen and the keyboard change.
    private var restHeight: NSLayoutConstraint?
    /// The most the opened rest of the queue takes before it scrolls: about three rows at the current text size, and
    /// never more than 30 % of the room above the keyboard (88 pt at least), so at large text, in landscape or with
    /// the keyboard up the card stays under the title instead of covering the chat.
    private var restCap: CGFloat {
        let rows = max(132, (HQFont.preferred(.subheadline).lineHeight * 2 + 12) * 3)
        guard let host = superview else { return rows }
        let room = host.keyboardLayoutGuide.layoutFrame.minY - host.safeAreaInsets.top
        return room > 0 ? min(rows, max(88, room * 0.3)) : rows
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The room changed (keyboard, rotation, window size): the opened rest follows, and the screen lays the dock out.
        guard let restHeight else { return }
        let cap = restCap
        guard abs(restHeight.constant - cap) > 0.5 else { return }
        restHeight.constant = cap
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }

    /// The words a queued item shows: its text, or for a hidden goal continuation (1x-activity §6.4) the words Hermes
    /// gave it (`display`, e.g. "/goal resume") or "Continue toward goal" — never Hermes's internal prompt.
    static func rowText(_ item: QueuedMessage) -> (text: String, quiet: Bool) {
        // MENUS (spec 1x §8.3): a queued skill send shows its invocation, never the expanded body.
        guard item.hidden else {
            // [drafts] A draft card's answer waits as its short words ("Send it"), as its bubble will read.
            let words = DraftCards.bubbleWords(item.text) ?? (item.display ?? item.text).replacingOccurrences(of: "\n", with: " ")
            // Nothing at all to show (no words, nothing attached, no memo): the web's "Empty Message" (spec §15.3).
            if words.trimmingCharacters(in: .whitespaces).isEmpty, item.attachments.isEmpty, item.memo == nil {
                return ("Empty Message", true)
            }
            return (words, false)
        }
        let display = item.display?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (display.isEmpty ? "Continue toward goal" : display.replacingOccurrences(of: "\n", with: " "), true)
    }

    private func row(_ item: QueuedMessage) -> UIView {
        let text = UILabel()
        text.font = HQFont.preferred(.subheadline)
        text.adjustsFontForContentSizeCategory = true
        let words = Self.rowText(item)        // [activity] a goal continuation in label-2
        text.textColor = words.quiet ? ChatPalette.label2 : ChatPalette.label
        text.lineBreakMode = .byTruncatingTail
        // Two lines before it cuts (one left a few letters at Extra Large); three when it has the row to itself.
        text.numberOfLines = stacked ? 3 : 2
        text.text = words.text
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // VOICE (spec 1x-voice §4.4): a queued memo reads "Voice Memo 0:12 · <first line typed>", after a mic glyph.
        var leading: [UIView] = []
        // [attachments] "Photo", "2 Photos", "report.pdf", "3 Attachments" and the first photo (docs/spec/1x-attachments.md §6.4)
        if let thumb = QueuedAttachmentSummary.thumbnail(item.attachments) { leading.append(thumb) }
        let typed = !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !item.attachments.isEmpty, !typed {
            text.text = QueuedAttachmentSummary.words(item.attachments)
        }
        if let memo = item.memo {
            let firstLine = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            text.text = "Voice Memo \(MemoPolicy.total(memo.seconds))" + (firstLine.isEmpty ? "" : " · " + firstLine)
            let mic = UIImageView(image: UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)))
            mic.tintColor = ChatPalette.label2
            mic.setContentHuggingPriority(.required, for: .horizontal)
            leading.append(mic)
        }
        // Spec §15.3: "Sending…" while it goes into the reply, "Editing" while its words are in the composer, and what
        // is attached when there are words too.
        let isSending = sending.contains(item.id)
        let isEditing = editing == item.id
        let captionText = QueueWords.caption(sending: isSending, editing: isEditing,
                                             attached: item.attachments.isEmpty || !typed ? nil : QueuedAttachmentSummary.words(item.attachments))
        var column: [UIView] = [text]
        if let captionText {
            let caption = UILabel()
            caption.font = HQFont.preferred(.footnote)
            caption.adjustsFontForContentSizeCategory = true
            caption.textColor = ChatPalette.label2
            caption.numberOfLines = 1
            caption.text = captionText
            caption.accessibilityIdentifier = "queue.caption"
            column.append(caption)
        }
        let wordsColumn = UIStackView(arrangedSubviews: column)
        wordsColumn.axis = .vertical
        wordsColumn.spacing = 3   // [ui-sizing] the words and their caption touched at 1
        let wordsRow = UIStackView(arrangedSubviews: leading + [wordsColumn])
        wordsRow.axis = .horizontal
        wordsRow.alignment = .center
        wordsRow.spacing = 8   // a photo's thumbnail or the mic glyph stands apart from the words (verify round 1)
        let menu = rowMenu(item, sending: isSending)
        // Tapping the words opens the same menu as ⋯ (spec §15.3); nothing here takes the keyboard.
        let body = QueueWordsButton(content: wordsRow)
        body.menu = menu
        body.showsMenuAsPrimaryAction = true
        body.accessibilityLabel = ([text.text ?? ""] + (captionText.map { [$0] } ?? [])).joined(separator: ", ")
        body.accessibilityHint = "Shows what you can do with this message"
        body.accessibilityIdentifier = "queue.words"
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var trailing: [UIView] = []
        if editing == nil, !isSending, canSendNow?(item) ?? true {
            var config = UIButton.Configuration.hqGlass()     // the Desktop Look's outlined button, not glass
            config.title = "Send Now"
            config.buttonSize = .small
            if !Theme.isDesktop { config.cornerStyle = .capsule }
            config.baseForegroundColor = ChatPalette.tint
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = HQFont.preferred(.subheadline)
                return out
            }
            let send = QueueRowButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                Haptics.play(.selection)
                self?.onSendNow?(item.id)
            })
            send.accessibilityLabel = "Send Now"
            // While a reply runs, Send Now steers: the message joins that reply (owner-approved, one label).
            send.accessibilityHint = running ? "Adds it to the current reply" : nil
            send.accessibilityIdentifier = "queue.sendnow"
            send.setContentHuggingPriority(.required, for: .horizontal)
            send.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.append(send)
        }
        trailing.append(moreButton(menu, words: text.text ?? ""))
        if stacked {
            let gap = UIView()
            gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let actions = UIStackView(arrangedSubviews: [gap] + trailing)
            actions.axis = .horizontal
            actions.alignment = .center
            actions.spacing = 2
            let row = UIStackView(arrangedSubviews: [body, actions])
            row.axis = .vertical
            row.spacing = 2
            row.accessibilityIdentifier = "chat.queue.item"
            return row
        }
        let row = UIStackView(arrangedSubviews: [body] + trailing)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.accessibilityIdentifier = "chat.queue.item"
        return row
    }

    /// The web's menu (spec §15.3), shared by ⋯ and the row's words: Send Now (when offered), Stop and Send (while a
    /// reply runs), Edit (typed words only; off while another row is being edited), Delete (off while it is going out).
    /// While a row is being edited the sends wait for Save or Cancel.
    private func rowMenu(_ item: QueuedMessage, sending: Bool) -> UIMenu {
        var children: [UIMenuElement] = []
        let steers = canSendNow?(item) ?? true
        if steers, editing == nil, !sending {
            let send = UIAction(title: "Send Now", image: UIImage(systemName: "arrow.up")) { [weak self] _ in self?.onSendNow?(item.id) }
            // While a reply runs the two sends differ: say how.
            if running { send.subtitle = "Adds it to the current reply" }
            children.append(send)
        }
        if running, editing == nil, !sending {
            let stopAndSend = UIAction(title: "Stop and Send", image: UIImage(systemName: "stop.fill")) { [weak self] _ in
                Haptics.play(.rigid)
                self?.onStopAndSend?(item.id)
            }
            stopAndSend.subtitle = "Stops the reply, then sends this"
            children.append(stopAndSend)
        }
        if canEdit?(item) ?? false, editing != item.id {   // [activity] a goal continuation has no words of yours to edit
            let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil"),
                                attributes: editing != nil || sending ? .disabled : []) { [weak self] _ in
                Haptics.play(.selection)
                self?.onEdit?(item.id)
            }
            edit.accessibilityIdentifier = "queue.edit"
            children.append(edit)
        }
        children.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"),
                                 attributes: sending ? [.destructive, .disabled] : .destructive) { [weak self] _ in
            Haptics.play(.light)
            self?.onDelete?(item.id)
        })
        // A photo or a slash command can't join a running reply: the menu says why Send Now isn't offered.
        return UIMenu(title: running && !steers && editing == nil ? "This can’t be added to the current reply" : "", children: children)
    }

    private func moreButton(_ menu: UIMenu, words: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        config.baseForegroundColor = ChatPalette.label2
        config.contentInsets = .zero
        let button = QueueRowButton(configuration: config)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        // VoiceOver names the message it is for ("More, Fix the typo"); Voice Control still answers to "More".
        button.accessibilityLabel = QueueWords.moreLabel(words)
        button.accessibilityUserInputLabels = ["More"]
        button.accessibilityIdentifier = "queue.more"
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    private func button(symbol: String, tint: UIColor, label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        config.baseForegroundColor = tint
        config.contentInsets = .zero
        let button = QueueRowButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        // 44 pt wide; 36 pt tall in the row (the card keeps its height) with a 44 pt tall touch target.
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }
}

/// A queue row's Send Now / ⋯: its touch target reaches 44 pt tall around the 36 pt row height.
private final class QueueRowButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }
}

/// A queue row's words (and its photo or mic glyph) as one button whose menu is the row's ⋯ menu. It dims while
/// pressed; its touch target reaches 44 pt tall, as the row's other buttons do.
private final class QueueWordsButton: UIButton {
    private let content: UIView

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    override var isHighlighted: Bool {
        didSet { content.alpha = isHighlighted ? 0.5 : 1 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }
}
