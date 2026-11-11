import UIKit

// [updates] An opened update group (UpdateGroups.swift): a centred inset card under the line, one table row per member,
// so opening a member rebuilds one row. Each row: the member's face or glyph, its words before the colon ("From Hermes")
// with its time trailing, and two lines of what it said; a tap swaps them for the whole message (or a work line's steps)
// and a second tap folds it (owner, 2026-10-28: "when you click it, it needs to be able to expand to show that in a way
// that's non-obtrusive, looks like we actually … tried when we designed it").

nonisolated struct UpdateMemberLayout: @unchecked Sendable {
    /// This row's piece of the card, in row coordinates (the rows of one card touch, so it reads as one box).
    var card: CGRect
    var first: Bool
    var last: Bool
    var mark: UpdatesGroup.Mark
    /// In card coordinates from here on.
    var markFrame: CGRect
    var title: String
    var titleFrame: CGRect
    var titleLines: Int
    var time: String?
    var timeFrame: CGRect
    /// A soft caret at the title line's end on a member that opens (down; up while open), as its line has.
    var caretFrame: CGRect?
    var preview: String
    var previewFrame: CGRect
    /// Opened: the whole message, formatted as the single line's card is (links tappable).
    var full: TextKitLayout?
    var fullFrame: CGRect
    /// Opened work line: its steps, each opening its sheet.
    var steps: [UpdateMemberStep]
    /// [files] The steps are a files member's files and its Review Changes row.
    var files = false
    var opens: Bool
    var expanded: Bool
    /// VoiceOver: "From Hermes, 8:45 PM, <preview>".
    var spoken: String
}

/// One step of an opened work-line member: its glyph, what it did ("Ran 1 command") and on what ("date; mail status").
nonisolated struct UpdateMemberStep {
    var title: String
    var detail: String?
    var glyph: ChatGlyph
    var failed: Bool
    var frame: CGRect
}

nonisolated enum UpdateMemberLayouts {
    static let padH: CGFloat = 12
    static let padV: CGFloat = 10
    /// Extra room at the card's top and bottom edges.
    static let edge: CGFloat = 4
    /// Under the card's last row: as far from the next row as a closed line's words are.
    static let after: CGFloat = 12

    /// The card: the reply column less 12 pt each side, so its edges don't line up with the bubbles' and it doesn't
    /// read as one more bot bubble (review 2026-10-28). [desktoplook] Replies have no bubble there and run from the text
    /// margin: the card is the reply column itself, so its edge sits on the text's grid (review 2026-10-28).
    static func cardWidth(_ width: CGFloat) -> CGFloat {
        HQShape.plainReplies ? TextLayout.replyWidth(width) : max(0, TextLayout.replyWidth(width) - 24)
    }

    static func cardX(_ width: CGFloat) -> CGFloat {
        HQShape.plainReplies ? ChatMetrics.sideInset : ((width - cardWidth(width)) / 2).rounded()
    }

    /// The caret's width: about the footnote's cap height (the line's own caret is the same).
    static func caretWidth(_ style: ChatStyle) -> CGFloat { max(7, style.notice.capHeight.rounded()) }

    static func make(_ m: UpdateMemberRow, gap: CGFloat, width: CGFloat, style: ChatStyle) -> RowLayout {
        let cardW = cardWidth(width)
        let cardX = cardX(width)
        let side = (style.toolGlyph + 4).rounded()
        let textX = padH + side + 10
        let lineH = ceil(style.tool.lineHeight)
        let bodyW = max(0, cardW - textX - padH)
        // The preview, measured as the label wraps (string drawing, not TextKit: the two disagree near the end of a
        // line), with room for its two lines; short of that it draws one. Cut, the member opens on its whole text.
        var previewH: CGFloat = 0
        var cut = false
        if !m.expanded, !m.preview.isEmpty {
            let needed = (m.preview as NSString).boundingRect(with: CGSize(width: bodyW, height: .greatestFiniteMagnitude),
                                                              options: [.usesLineFragmentOrigin], attributes: [.font: style.tool],
                                                              context: nil).height
            let twoLines = ceil(style.tool.lineHeight * 2) + 2
            cut = needed > twoLines
            previewH = min(ceil(needed) + 1, twoLines)
        }
        let opens = m.opens || cut || m.expanded
        // A one-step work line opens its sheet, not the row: no caret. Its slot is kept on every row all the same, so
        // the times of one card share a trailing edge (review 2026-10-28: "10:44 PM ⌄" sat 12 pt left of "10:45 PM").
        let slotW = caretWidth(style)
        let caretW: CGFloat = opens && !(m.steps.count == 1 && m.thought == nil) ? slotW : 0
        let caretRoom = slotW + 8
        let clock = m.time.map { ChatRowBuilder.clock($0) }
        // [idle] A group that spans days says each row's day before its time ("Nov 2 2:22 PM").
        var time = clock.map { c in m.day.map { "\($0) \(c)" } ?? c }
        func measure(_ time: String?) -> CGFloat { time.map { ceil(($0 as NSString).size(withAttributes: [.font: style.notice]).width) } ?? 0 }
        var timeW = measure(time)
        let titleRoom = max(0, cardW - textX - padH - caretRoom)
        let titleNatural = ceil((m.title as NSString).size(withAttributes: [.font: style.tool]).width)
        // The title keeps its words and the time stays beside it, never on a line of its own: when the two don't fit on
        // one line (large text) the time drops its AM/PM ("11:23"); still too long, the row shows no time (review
        // 2026-10-28: "11:23 PM" alone on a line under the preview). VoiceOver still says it.
        if time != nil, titleNatural + 8 + timeW > titleRoom {
            // [idle] A dated time drops its AM/PM, then its clock ("Nov 2"), before it goes.
            let tries = [time.map(Self.shortClock), m.day].compactMap { $0 }
            time = tries.first { titleNatural + 8 + measure($0) <= titleRoom }
            timeW = measure(time)
        }
        let titleW = time != nil ? max(0, titleRoom - timeW - 8) : titleRoom
        var y = (m.first ? edge : 0) + padV
        // A note's words are its title: up to two lines.
        var titleH = lineH
        var titleLines = 1
        if m.notice {
            let tk = TextKitLayout(NSAttributedString(string: m.title, attributes: [.font: style.tool]), width: titleW)
            titleLines = tk.size.height > lineH * 1.5 ? 2 : 1
            titleH = titleLines == 2 ? ceil(style.tool.lineHeight * 2) : lineH
        }
        let titleFrame = CGRect(x: textX, y: y, width: titleW, height: titleH)
        let timeH = ceil(style.notice.lineHeight)
        let markFrame = CGRect(x: padH, y: y + ((lineH - side) / 2).rounded(), width: side, height: side)
        let caretH = (caretW * 0.5).rounded()
        let caretFrame: CGRect? = caretW > 0
            ? CGRect(x: cardW - padH - caretW, y: y + ((lineH - caretH) / 2).rounded(), width: caretW, height: caretH) : nil
        y += titleH
        var timeFrame = CGRect.zero
        if time != nil {
            timeFrame = CGRect(x: cardW - padH - caretRoom - timeW, y: titleFrame.minY + ((lineH - timeH) / 2).rounded(),
                               width: timeW, height: timeH)
        }
        var full: TextKitLayout?
        var fullFrame = CGRect.zero
        var previewFrame = CGRect.zero
        var steps: [UpdateMemberStep] = []
        let listsSteps = m.expanded && (m.steps.count > 1 || m.thought != nil)
        if m.expanded, !m.files.isEmpty {
            // [files] "5 files changed" opened: a row per file (it opens the file), then Review Changes (the chat's
            // Changes page), drawn as a work line's steps are.
            y += 2
            let glyphSide = stepGlyphSide(style)
            var listed = m.files.map { UpdateMemberStep(title: $0.name, detail: fileCounts($0), glyph: .file, failed: false, frame: .zero) }
            listed.append(UpdateMemberStep(title: "Review Changes", detail: nil, glyph: .explore, failed: false, frame: .zero))
            for step in listed {
                let wordsW = max(0, bodyW - glyphSide - 8 - caretRoom)
                let needed = stepWords(step, style: style).boundingRect(with: CGSize(width: wordsW, height: .greatestFiniteMagnitude),
                                                                        options: [.usesLineFragmentOrigin], context: nil).height
                let wordsH = min(ceil(needed) + 1, ceil(style.tool.lineHeight * 2) + 2)
                var placed = step
                placed.frame = CGRect(x: textX, y: y, width: bodyW, height: max(lineH, wordsH) + 12)
                steps.append(placed)
                y += placed.frame.height
            }
        } else if listsSteps {
            // A work line opened as the One Line row opens: its thought, then a row per step, each opening its sheet.
            if let thought = m.thought {
                let tk = TextKitLayout(TextLayout.resultText(thought, links: .none, style: style), width: bodyW)
                full = tk
                fullFrame = CGRect(x: textX, y: y + 4, width: tk.size.width, height: tk.size.height)
                y += 4 + tk.size.height
            }
            y += 2
            // Each step: its words beside its glyph, wrapping to a second line rather than cut after a word or two
            // (review 2026-10-28: "Read-only fresh…"), its chevron in the members' caret slot.
            let glyphSide = stepGlyphSide(style)
            let failedW = ceil(("Failed" as NSString).size(withAttributes: [.font: style.toolMeta]).width) + 6
            for call in m.steps {
                let title = ChatRunSummary.summarize([call], live: false)
                let step = UpdateMemberStep(title: title, detail: detail(call, title: title),
                                            glyph: stepGlyph(title),
                                            failed: call.state == .failed, frame: .zero)
                let wordsW = max(0, bodyW - glyphSide - 8 - caretRoom - (step.failed ? failedW : 0))
                let needed = stepWords(step, style: style).boundingRect(with: CGSize(width: wordsW, height: .greatestFiniteMagnitude),
                                                                        options: [.usesLineFragmentOrigin], context: nil).height
                let wordsH = min(ceil(needed) + 1, ceil(style.tool.lineHeight * 2) + 2)
                var placed = step
                placed.frame = CGRect(x: textX, y: y, width: bodyW, height: max(lineH, wordsH) + 12)
                steps.append(placed)
                y += placed.frame.height
            }
        } else if m.expanded && !m.full.isEmpty {
            // The whole words in the reply's own type, as a run of one opens (owner, 2026-10-27: legible, "not a block of
            // small grey text"); the member's caret turns up to say it folds again.
            let tk = TextKitLayout(TextLayout.resultText(m.full, links: m.process ? .addresses : .formatted, style: style), width: bodyW)
            full = tk
            fullFrame = CGRect(x: textX, y: y + 2, width: tk.size.width, height: tk.size.height)
            y += 2 + tk.size.height
        } else if previewH > 0 {
            previewFrame = CGRect(x: textX, y: y + 2, width: bodyW, height: previewH)
            y += 2 + previewH
        }
        y += padV + (m.last ? edge : 0)
        let cardH = ceil(y)
        let spoken = [m.title, clock, m.preview.isEmpty ? nil : m.preview].compactMap { $0 }.joined(separator: ", ")
        let layout = UpdateMemberLayout(card: CGRect(x: cardX, y: max(0, gap), width: cardW, height: cardH), first: m.first, last: m.last,
                                        mark: m.mark, markFrame: markFrame, title: m.title, titleFrame: titleFrame,
                                        titleLines: titleLines, time: time, timeFrame: timeFrame, caretFrame: caretFrame,
                                        preview: m.preview, previewFrame: previewFrame, full: full, fullFrame: fullFrame,
                                        steps: steps, files: !m.files.isEmpty, opens: opens, expanded: m.expanded, spoken: spoken)
        return RowLayout(height: max(0, gap) + cardH + (m.last ? after : 0), content: .member(layout))
    }

    static func stepGlyphSide(_ style: ChatStyle) -> CGFloat { (style.toolGlyph - 2).rounded() }

    /// [files] A file's edits and lines after its name ("2 edits · +3 −1"); nil when its diffs counted nothing.
    static func fileCounts(_ file: ChangedFile) -> String? {
        var parts: [String] = []
        if file.edits > 1 { parts.append("\(file.edits) edits") }
        let lines = [file.added > 0 ? "+\(file.added)" : nil, file.removed > 0 ? "−\(file.removed)" : nil].compactMap { $0 }
        if !lines.isEmpty { parts.append(lines.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A clock time without its AM/PM ("11:23 PM" → "11:23"), for a row too narrow for the whole of it.
    static func shortClock(_ time: String) -> String {
        let cut = time.replacingOccurrences(of: #"[\s\x{202F}\x{00A0}]*[AaPp]\.?\s?[Mm]\.?$"#, with: "", options: .regularExpression)
        return cut.isEmpty ? time : cut
    }

    /// A step's glyph: a delegated task is a helper's work, so it takes the helpers' small bot, as their rows and the
    /// line's mark do (review 2026-10-28: a wrench beside "Delegated 1 task").
    static func stepGlyph(_ summary: String) -> ChatGlyph {
        summary.hasPrefix("Delegat") ? .subagent : ChatRunSummary.glyph(forSummary: summary)
    }

    /// A step's words: what it did, then (in label 2) on what.
    static func stepWords(_ step: UpdateMemberStep, style: ChatStyle) -> NSAttributedString {
        let words = NSMutableAttributedString(string: step.title, attributes: [.font: style.tool, .foregroundColor: ChatPalette.label])
        if let detail = step.detail {
            words.append(NSAttributedString(string: "  " + detail, attributes: [.font: style.tool, .foregroundColor: ChatPalette.label2]))
        }
        // Lines fill before they break: the default strategy pushed words down to spare a lone one, leaving the first
        // line half empty ("Ran 1 command  mail" / "thread 1234"; review 2026-10-28).
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = []
        words.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: words.length))
        return words
    }

    /// What a step worked on, after what it did: its own words when they say more than its summary, else the command,
    /// path, query or address it was given ("Ran 1 command  date; mail status").
    private static func detail(_ call: ToolCall, title: String) -> String? {
        let words = ChatText.trimmed(call.title)
        if !words.isEmpty, words != call.name, words != title { return words }
        let args = ToolArgs.parse(call.argsText)
        for key in ["command", "path", "file_path", "query", "url", "goal"] {
            if let value = args[key]?.string, !ChatText.trimmed(value).isEmpty {
                // "Edited overview.md" already names notes/overview.md.
                if title.contains((value as NSString).lastPathComponent) { return nil }
                return ChatText.trimmed(value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
            }
        }
        return nil
    }
}

final class UpdateMemberCell: ChatBaseCell, UIContextMenuInteractionDelegate {
    static let reuse = "updateMember"
    /// This row's piece of the card: the fill, the corners of the card's ends, and the press highlight inside them.
    private let piece = UIView()
    private let highlight = UIView()
    private let button = UIControl()
    private let glyph = CAShapeLayer()
    private var head: HeadView?
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let previewLabel = UILabel()
    private let fullText = TextDrawView()
    private let caret = CAShapeLayer()
    private var stepViews: [(control: UIControl, glyph: CAShapeLayer, title: UILabel, meta: UILabel, chevron: CAShapeLayer)] = []
    private weak var linkTap: UITapGestureRecognizer?
    private var currentGlyph: ChatGlyph?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(piece)
        piece.clipsToBounds = true
        piece.layer.cornerCurve = .continuous
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        piece.addSubview(highlight)
        piece.addSubview(button)
        glyph.fillColor = nil
        glyph.lineWidth = 1.5
        glyph.lineCap = .round
        glyph.lineJoin = .round
        button.layer.addSublayer(glyph)
        for shape in [glyph, caret] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        caret.lineWidth = 1.5
        button.layer.addSublayer(caret)
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.textAlignment = .right
        previewLabel.numberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, timeLabel, previewLabel] {
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            button.addSubview(label)
        }
        fullText.isAccessibilityElement = true
        fullText.accessibilityTraits = .staticText
        fullText.accessibilityIdentifier = "chat.tool.opened"
        piece.addSubview(fullText)
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "chat.update.member"
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        button.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        // Held: Copy, Read Aloud and Share, as a single update's line offers.
        button.addInteraction(UIContextMenuInteraction(delegate: self))
        // A link in the opened words opens; the tap doesn't also fold the row (it begins only on a link).
        let links = UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:)))
        // The row's own tap still lands: left cancelling, this recognizer ended every tap on a closed row (owner,
        // 2026-10-29: "I can't click on the 'from Otto' messages"), as the line's own link tap would.
        links.cancelsTouchesInView = false
        addGestureRecognizer(links)
        linkTap = links
        #if targetEnvironment(macCatalyst)
        // [mac] Mac audit 2026-11-02 #11: an opened member's words select with a drag, as a bubble's do
        // (ChatTextSelection.swift); a click still folds it.
        textSelector = ChatTextSelector(host: piece, owner: self, surfaces: { [weak self] in
            guard let self, !self.fullText.isHidden else { return [] }
            return [self.fullText]
        }, color: { DesktopFrost.tint(ChatPalette.tint) })
        #endif
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (cell: UpdateMemberCell, _) in
            cell.updateColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateColors() {
        piece.backgroundColor = Self.contentCardFill
        highlight.backgroundColor = ChatPalette.fill4
        glyph.strokeColor = ChatPalette.label2.resolvedColor(with: traitCollection).cgColor
        caret.strokeColor = ChatPalette.label3.resolvedColor(with: traitCollection).cgColor
        for entry in stepViews {
            entry.glyph.strokeColor = glyph.strokeColor
            entry.chevron.strokeColor = caret.strokeColor
        }
        titleLabel.textColor = ChatPalette.label
        timeLabel.textColor = ChatPalette.label3
        previewLabel.textColor = ChatPalette.label2
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .member(let m) = layout.content else { return }
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        piece.frame = m.card
        piece.backgroundColor = Self.contentCardFill   // [backdrop]
        piece.layer.cornerRadius = ChatMetrics.insetCardRadius
        var corners: CACornerMask = []
        if m.first { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if m.last { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        piece.layer.maskedCorners = corners
        highlight.frame = piece.bounds
        // The opened words lie under the button's tap area only where they aren't (links in them open).
        button.frame = piece.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch m.mark {
        case .glyph(let g):
            glyph.isHidden = false
            head?.isHidden = true
            let size = (m.markFrame.width - 4).rounded()
            glyph.frame = CGRect(x: m.markFrame.midX - size / 2, y: m.markFrame.midY - size / 2, width: size, height: size)
            if currentGlyph != g || glyph.path == nil { glyph.path = g.path(size: size) }
            currentGlyph = g
        case .face(let sender):
            glyph.isHidden = true
            let view = head ?? {
                let made = HeadView(side: m.markFrame.width, mark: true)
                made.isUserInteractionEnabled = false
                button.addSubview(made)
                head = made
                return made
            }()
            view.isHidden = false
            view.frame = m.markFrame
            view.configure(raw: sender.head, profile: sender.profile)
        }
        caret.isHidden = m.caretFrame == nil
        if let frame = m.caretFrame {
            caret.frame = frame
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: m.expanded ? frame.height : 0))
            path.addLine(to: CGPoint(x: frame.width / 2, y: m.expanded ? 0 : frame.height))
            path.addLine(to: CGPoint(x: frame.width, y: m.expanded ? frame.height : 0))
            caret.path = path.cgPath
        }
        CATransaction.commit()
        titleLabel.font = style.tool
        titleLabel.numberOfLines = m.titleLines
        titleLabel.text = m.title
        titleLabel.frame = m.titleFrame
        timeLabel.font = style.notice
        timeLabel.text = m.time
        timeLabel.isHidden = m.time == nil
        timeLabel.frame = m.timeFrame
        previewLabel.font = style.tool
        previewLabel.text = m.preview
        previewLabel.isHidden = m.previewFrame.isEmpty
        previewLabel.frame = m.previewFrame
        if let tk = m.full {
            fullText.isHidden = false
            fullText.frame = m.fullFrame
            fullText.set(layout: tk)
            fullText.accessibilityLabel = tk.text.string
        } else {
            fullText.isHidden = true
        }
        #if targetEnvironment(macCatalyst)
        textSelector?.refresh()   // [mac] #11: drawn again on the new words; put away once they fold
        #endif
        configureSteps(m, style: style)
        updateColors()
        button.isEnabled = m.opens || !m.steps.isEmpty
        button.accessibilityLabel = m.spoken
        button.accessibilityTraits = m.opens ? .button : .staticText
        button.accessibilityValue = m.opens && (m.steps.isEmpty || m.files) ? (m.expanded ? "Expanded" : "Collapsed") : nil
        button.accessibilityCustomActions = m.full.flatMap { linkActions($0.text) }
    }

    private func configureSteps(_ m: UpdateMemberLayout, style: ChatStyle) {
        while stepViews.count < m.steps.count {
            let control = UIControl()
            let title = UILabel(), meta = UILabel()
            let mark = CAShapeLayer(), chevron = CAShapeLayer()
            for shape in [mark, chevron] {
                shape.fillColor = nil
                shape.lineWidth = 1.5
                shape.lineCap = .round
                shape.lineJoin = .round
                control.layer.addSublayer(shape)
            }
            title.lineBreakMode = .byTruncatingTail
            title.numberOfLines = 2
            meta.textAlignment = .right
            meta.textColor = ChatPalette.red
            meta.text = "Failed"
            control.addSubview(title)
            control.addSubview(meta)
            control.tag = stepViews.count
            control.addTarget(self, action: #selector(openStep(_:)), for: .touchUpInside)
            control.isAccessibilityElement = true
            control.accessibilityTraits = .button
            piece.addSubview(control)
            stepViews.append((control, mark, title, meta, chevron))
        }
        let glyphSide = UpdateMemberLayouts.stepGlyphSide(style)
        // The chevron is the members' caret turned to point right: the same slot, size, stroke and colour.
        let slotW = UpdateMemberLayouts.caretWidth(style)
        let chevronW = (slotW * 0.5).rounded(), chevronH = slotW
        let lineH = ceil(style.tool.lineHeight)
        for (i, entry) in stepViews.enumerated() {
            guard i < m.steps.count else { entry.control.isHidden = true; continue }
            let step = m.steps[i]
            let h = step.frame.height
            entry.control.isHidden = false
            entry.control.frame = step.frame
            // Its glyph, what it did and (in label 2) on what, and a soft chevron: each step opens its sheet. Glyph,
            // chevron and Failed sit on the first line when the words wrap.
            let firstMid = 6 + lineH / 2
            entry.glyph.frame = CGRect(x: 0, y: (firstMid - glyphSide / 2).rounded(), width: glyphSide, height: glyphSide)
            entry.glyph.path = step.glyph.path(size: glyphSide)
            entry.chevron.frame = CGRect(x: step.frame.width - ((slotW + chevronW) / 2).rounded(), y: (firstMid - chevronH / 2).rounded(),
                                         width: chevronW, height: chevronH)
            let chevron = UIBezierPath()
            chevron.move(to: .zero)
            chevron.addLine(to: CGPoint(x: chevronW, y: chevronH / 2))
            chevron.addLine(to: CGPoint(x: 0, y: chevronH))
            entry.chevron.path = chevron.cgPath
            entry.meta.font = style.toolMeta
            entry.meta.isHidden = !step.failed
            let metaW = step.failed ? ceil(("Failed" as NSString).size(withAttributes: [.font: style.toolMeta]).width) : 0
            let slotX = step.frame.width - slotW - 8
            entry.meta.frame = CGRect(x: slotX - metaW, y: 6, width: metaW, height: lineH)
            entry.title.attributedText = UpdateMemberLayouts.stepWords(step, style: style)
            entry.title.lineBreakMode = .byTruncatingTail
            entry.title.lineBreakStrategy = []
            let titleX = glyphSide + 8
            let end = metaW > 0 ? entry.meta.frame.minX - 6 : slotX
            entry.title.frame = CGRect(x: titleX, y: 6, width: max(0, end - titleX), height: h - 12)
            entry.control.accessibilityLabel = [step.title, step.detail, step.failed ? "Failed" : nil].compactMap { $0 }.joined(separator: ", ")
            entry.control.accessibilityHint = m.files ? nil : "Shows the step’s details"
        }
    }

    private func link(at gr: UIGestureRecognizer) -> URL? {
        guard !fullText.isHidden else { return nil }
        let p = gr.location(in: fullText)
        return fullText.bounds.insetBy(dx: -6, dy: -6).contains(p) ? fullText.link(at: p) : nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTap { return link(at: gestureRecognizer) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func linkTapped(_ gr: UITapGestureRecognizer) {
        guard let url = link(at: gr) else { return }
        delegate?.chatCellOpen(url: url)
    }

    private func linkActions(_ string: NSAttributedString) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        string.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            guard let url = value as? URL else { return }
            actions.append(UIAccessibilityCustomAction(name: "Open \(url.host() ?? url.absoluteString)") { [weak self] _ in
                self?.delegate?.chatCellOpen(url: url)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    @objc private func toggle() {
        #if targetEnvironment(macCatalyst)
        if let active = ChatTextSelector.active, active.hasSelection { active.clear(); return }   // [mac] #11: a click puts it away
        #endif
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
    }

    @objc private func openStep(_ sender: UIControl) { delegate?.chatCellOpenStep(rowId: rowId, index: sender.tag) }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let menu = delegate?.chatCellRowMenu(rowId: rowId, source: button)
        #if targetEnvironment(macCatalyst)
        // [mac] #11: with part of the words selected, Copy Selection takes that part, ahead of the row's own menu.
        if let selected = textSelector?.selectedText {
            menu.map(ChatTextSelector.nameWholeCopy)
            let copy = UIAction(title: "Copy Selection", image: UIImage(systemName: "text.cursor")) { _ in UIPasteboard.general.string = selected }
            copy.accessibilityIdentifier = "selection.copy"
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [copy] + (menu.map { [UIMenu(options: .displayInline, children: $0.children)] } ?? []))
            }
        }
        #endif
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    #if targetEnvironment(macCatalyst)
    // MARK: [mac] Selecting the opened words (Mac audit #11)

    private var textSelector: ChatTextSelector?

    #if DEBUG
    var debugSelector: ChatTextSelector? { textSelector }
    var debugHost: UIView { piece }
    var debugOpenedWords: TextDrawView? { fullText.isHidden ? nil : fullText }
    /// A closed reply showing its first words, which opens to the whole words (not a one-step line's sheet).
    var debugOpensToWords: Bool { fullText.isHidden && !previewLabel.isHidden }
    func debugOpen() { delegate?.chatCellToggle(rowId: rowId) }
    #endif

    override func prepareForReuse() {
        super.prepareForReuse()
        textSelector?.clear()
    }

    override var canBecomeFirstResponder: Bool { textSelector?.hasSelection ?? false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return textSelector?.selectedText != nil }
        if action == #selector(selectAll(_:)) { return textSelector?.isActive ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) { textSelector?.copySelection() }

    override func selectAll(_ sender: Any?) { textSelector?.selectAll() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { textSelector?.clear(resign: false) }
        return resigned
    }
    #endif

    // The highlight stays inside the card, clipped to its corners.
    @objc private func pressDown() { highlight.alpha = 1 }
    @objc private func pressUp() { UIView.animate(withDuration: 0.2) { self.highlight.alpha = 0 } }   // motion-ok: colour only
}
