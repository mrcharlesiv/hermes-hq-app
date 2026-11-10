import ImageIO
import UIKit

// Cells for the activity rows (docs/spec/1x-activity.md §10.2, §11): the Telegram-style tool bubble, the delegate card
// with its one-line live ticker, and the generated-image frame. Frames come from `ActivityLayouts` (no Auto Layout).

/// What the activity cells ask of the chat screen (ChatViewController adopts it in ChatActivityController.swift).
@MainActor protocol ActivityCellDelegate: AnyObject {
    /// A tool bubble line was tapped: its step sheet.
    func activityCellOpenStep(rowId: String, call: ToolCall)
    /// The generated image (its bytes), loaded for the frame at `maxPixel`.
    func activityCellLoadImage(path: String, maxPixel: Int) async throws -> UIImage
    func activityCellOpenImage(_ image: UIImage, path: String, from view: UIView)
    /// A good path wouldn't load: its row becomes the 44 pt "Open image: …" link row (`retry` false), or back to the
    /// frame for another try (`retry` true).
    func activityCellImageFailed(rowId: String, path: String, retry: Bool)
    /// [transcript] A changed file tapped (the card, or a diff preview's own header — n20 F10): its current text, the
    /// same opener a bot's own `#file:` link uses (`path` exactly as the edit tool reported it; relative paths resolve
    /// against the chat's folder before opening).
    func activityCellOpenFile(path: String)
    /// [transcript] "Review" on the files card, or "Review in Changes" held on one of its rows: the chat's Changes
    /// page, with `highlighting` selected once it has loaded (nil: just opens).
    func activityCellReviewChanges(highlighting path: String?)
    /// [tasks] "Added to Tasks": a task's row (its sheet on the Tasks page), or Open Tasks (`id` nil).
    func activityCellOpenTask(id: String?)
    /// [tasks] Its Undo: the tasks are deleted; `done` says whether they all went.
    func activityCellUndoTasks(ids: [String], done: @escaping (Bool) -> Void)
    /// [tasks] "Ask Hermes to Help": asks this chat's bot to take its part of that task of yours.
    func activityCellAskHelp(taskId: String, title: String)
}

enum ActivityCells {
    static func register(in table: UITableView) {
        table.register(ToolBubbleCell.self, forCellReuseIdentifier: ToolBubbleCell.reuse)
        table.register(DelegateCardCell.self, forCellReuseIdentifier: DelegateCardCell.reuse)
        table.register(ImageCardCell.self, forCellReuseIdentifier: ImageCardCell.reuse)
        table.register(ChangedFilesCell.self, forCellReuseIdentifier: ChangedFilesCell.reuse)
        table.register(DiffPreviewCell.self, forCellReuseIdentifier: DiffPreviewCell.reuse)
        table.register(TasksAddedCell.self, forCellReuseIdentifier: TasksAddedCell.reuse)
    }

    static func reuse(for kind: ActivityRowKind) -> String {
        switch kind {
        case .toolBubble: return ToolBubbleCell.reuse
        case .delegate: return DelegateCardCell.reuse
        case .image: return ImageCardCell.reuse
        case .changedFiles: return ChangedFilesCell.reuse
        case .diffPreview: return DiffPreviewCell.reuse
        case .tasksAdded: return TasksAddedCell.reuse
        }
    }
}

// MARK: - Tool bubble (§10.2)

final class ToolBubbleCell: ChatBaseCell {
    static let reuse = "activity.toolBubble"
    private let bubble = UIView()
    private let shape = BubbleShapeView()
    private let more = UIControl()
    private let moreText = TextDrawView()
    private let timeLabel = UILabel()
    private var lineViews: [LineView] = []
    private var calls: [String: ToolCall] = [:]

    /// One line: its text, the code block; the view itself is the ≥ 44 pt tap target (neighbours' targets overlap).
    private final class LineView: UIControl {
        let text = TextDrawView()
        let block = UIView()
        let bar = UIView()
        let head = TextDrawView()
        let code = TextDrawView()
        var callId = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(text)
            block.layer.cornerRadius = 6
            block.layer.cornerCurve = .continuous
            block.clipsToBounds = true
            block.isUserInteractionEnabled = false
            block.addSubview(bar)
            block.addSubview(head)
            block.addSubview(code)
            addSubview(block)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool {
            didSet { text.alpha = isHighlighted ? 0.5 : 1; block.alpha = isHighlighted ? 0.5 : 1 }
        }

    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        bubble.clipsToBounds = false
        contentView.addSubview(bubble)
        bubble.addSubview(shape)
        more.addSubview(moreText)
        more.addTarget(self, action: #selector(showAll), for: .touchUpInside)
        more.isAccessibilityElement = true
        more.accessibilityTraits = .button
        bubble.addSubview(more)
        bubble.addSubview(timeLabel)
        accessibilityIdentifier = "chat.tool-bubble"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.toolBubble(let t)) = layout.content, case .activity(.toolBubble(let spec)) = row.kind else { return }
        calls = Dictionary(spec.calls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        bubble.frame = t.frame
        shape.frame = bubble.bounds
        shape.fill = ChatPalette.botBubble
        shape.key = t.shape
        if let m = t.more {
            more.isHidden = false
            more.frame = CGRect(x: 0, y: t.moreFrame.minY - max(0, (44 - t.moreFrame.height) / 2), width: t.frame.width,
                                height: max(44, t.moreFrame.height))
            moreText.frame = CGRect(x: t.moreFrame.minX, y: t.moreFrame.minY - more.frame.minY, width: t.moreFrame.width, height: t.moreFrame.height)
            moreText.set(layout: m)
            more.accessibilityLabel = m.text.string
        } else {
            more.isHidden = true
        }
        while lineViews.count < t.lines.count {
            let v = LineView()
            v.addTarget(self, action: #selector(lineTapped(_:)), for: .touchUpInside)
            bubble.insertSubview(v, belowSubview: more)
            lineViews.append(v)
        }
        let accent = ChatPalette.tint
        for (i, v) in lineViews.enumerated() {
            guard i < t.lines.count else { v.isHidden = true; continue }
            let l = t.lines[i]
            v.isHidden = false
            v.callId = l.callId
            v.frame = l.tapFrame
            let origin = l.tapFrame.origin
            v.text.frame = l.textFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.text.set(layout: l.text)
            v.isEnabled = !l.running
            v.accessibilityLabel = l.accessibility
            if let block = l.blockFrame, let head = l.head, let code = l.code {
                v.block.isHidden = false
                v.block.frame = block.offsetBy(dx: -origin.x, dy: -origin.y)
                v.block.backgroundColor = accent.withAlphaComponent(0.1)
                v.bar.backgroundColor = accent
                v.bar.frame = CGRect(x: 0, y: 0, width: 3, height: block.height)
                v.head.frame = l.headFrame
                v.head.set(layout: head)
                v.code.frame = l.codeFrame
                v.code.set(layout: code)
                v.code.clipsToBounds = true
                Shimmer.set(l.running, on: v.code, contentToken: v.code.drawGeneration)
                Shimmer.set(false, on: v.text)
            } else {
                v.block.isHidden = true
                Shimmer.set(l.running, on: v.text, contentToken: v.text.drawGeneration)
            }
        }
        if let time = t.timeText {
            timeLabel.isHidden = false
            let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
            timeLabel.attributedText = NSAttributedString(string: time, attributes: [.font: style.time, .foregroundColor: ChatPalette.label2])
            timeLabel.frame = t.timeFrame
        } else {
            timeLabel.isHidden = true
        }
    }

    @objc private func lineTapped(_ sender: UIControl) {
        guard let v = sender as? LineView, let call = calls[v.callId] else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenStep(rowId: rowId, call: call)
    }

    @objc private func showAll() {
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
    }
}

// MARK: - Delegate card (§11.2)

/// One line of activity in a window one line tall: a new line slides up in as the old one slides out (0.2 s).
final class TickerView: UIView {
    private var current = UILabel()
    private(set) var text: String?
    var font: UIFont = HQFont.scaled(14, like: .subheadline, cap: 24) { didSet { current.font = font; if font != oldValue { drawGeneration += 1 } } }
    var color: UIColor = ChatPalette.label2 { didSet { current.textColor = color; if color != oldValue { drawGeneration += 1 } } }
    /// Goes up whenever the drawing changes (the shimmer's glow re-snapshots the line only then).
    private(set) var drawGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(current)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ text: String?, animated: Bool) {
        guard text != self.text else { return }
        let old = self.text
        self.text = text
        drawGeneration += 1
        guard animated, old != nil, text != nil, window != nil, !HQMotion.reduced else {
            current.layer.removeAllAnimations()
            current.text = text
            current.frame = bounds
            return
        }
        let outgoing = current
        let incoming = UILabel()
        incoming.font = font
        incoming.textColor = color
        incoming.text = text
        incoming.lineBreakMode = .byTruncatingTail
        incoming.frame = bounds.offsetBy(dx: 0, dy: bounds.height)
        addSubview(incoming)
        current = incoming
        // The desktop's reel (V:styles.css `.tool-ticker__reel`): the line before slides up and out of a one-line
        // window as the new one slides in, 240 ms on cubic-bezier(0.22, 1, 0.36, 1), a move with no fade.
        let roll = UIViewPropertyAnimator(duration: 0.24, controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1)) {   // motion-ok: Reduce Motion returned in the guard above
            outgoing.frame = self.bounds.offsetBy(dx: 0, dy: -self.bounds.height)
            incoming.frame = self.bounds
        }
        roll.addCompletion { _ in outgoing.removeFromSuperview() }
        roll.startAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if current.layer.animationKeys()?.isEmpty ?? true { current.frame = bounds }
        current.lineBreakMode = .byTruncatingTail
    }
}

final class DelegateCardCell: ChatBaseCell {
    static let reuse = "activity.delegate"

    private final class RowView: UIView {
        let border = CAShapeLayer()
        let breathe = GlyphSpinner(style: .breathe, color: ChatPalette.label3, size: HQFont.symbolSize(13, like: .footnote, cap: 22))
        let status = UIImageView()
        let dot = UIView()
        let goal = UILabel()
        let meta = UILabel()
        let timer = UILabel()
        let agent = UIImageView(image: UIImage(systemName: "person.2.circle"))
        let ticker = TickerView()
        var startedAt: Double?

        override init(frame: CGRect) {
            super.init(frame: frame)
            border.fillColor = nil
            border.lineWidth = 0.5
            layer.addSublayer(border)
            status.contentMode = .scaleAspectFit
            dot.layer.cornerRadius = 3
            for v: UIView in [breathe, status, dot, goal, meta, timer, agent, ticker] { addSubview(v) }
            agent.tintColor = ChatPalette.label3
            agent.contentMode = .scaleAspectFit
            timer.textAlignment = .right
            timer.textColor = ChatPalette.label2
            goal.lineBreakMode = .byTruncatingTail
            goal.textColor = ChatPalette.label
            meta.lineBreakMode = .byTruncatingTail
            meta.textColor = ChatPalette.label2
            isAccessibilityElement = true
            registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: RowView, _) in
                view.border.strokeColor = ChatPalette.separator.resolvedColor(with: view.traitCollection).cgColor
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func tick() {
            guard let startedAt, !timer.isHidden else { return }
            timer.text = SubagentRules.formatElapsed(Int(Date().timeIntervalSince1970 - startedAt))
        }
    }

    private var rowViews: [RowView] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessibilityIdentifier = "chat.delegate-card"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        let sameRow = row.id == rowId
        super.configure(row, layout: layout)
        guard case .activity(.delegate(let d)) = layout.content else { return }
        while rowViews.count < d.rows.count {
            let v = RowView()
            contentView.addSubview(v)
            rowViews.append(v)
        }
        var anyLive = false
        let tabular = HQFont.monoDigitFace(ofSize: d.font.pointSize, weight: .regular)
        for (i, v) in rowViews.enumerated() {
            guard i < d.rows.count else { v.isHidden = true; continue }
            let r = d.rows[i]
            v.isHidden = false
            v.frame = r.frame
            CATransaction.begin(); CATransaction.setDisableActions(true)
            v.border.path = UIBezierPath(roundedRect: v.bounds.insetBy(dx: 0.25, dy: 0.25), cornerRadius: HQShape.radius(18, .card)).cgPath
            v.border.strokeColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
            CATransaction.commit()
            let live = r.status.isLive
            anyLive = anyLive || live
            v.breathe.isHidden = !live
            v.breathe.frame = r.glyphFrame.insetBy(dx: -2, dy: -2)
            v.dot.isHidden = r.status != .dispatched
            v.dot.backgroundColor = ChatPalette.label3
            v.dot.frame = CGRect(x: r.glyphFrame.midX - 3, y: r.glyphFrame.midY - 3, width: 6, height: 6)
            switch r.status {
            case .completed:
                v.status.isHidden = false
                v.status.image = UIImage(systemName: "checkmark.circle.fill")
                v.status.tintColor = ChatPalette.green
            case .failed, .interrupted:
                v.status.isHidden = false
                v.status.image = UIImage(systemName: "exclamationmark.circle.fill")
                v.status.tintColor = ChatPalette.red
            default:
                v.status.isHidden = true
            }
            v.status.frame = r.glyphFrame
            v.goal.frame = r.goalFrame
            v.goal.font = d.font
            v.goal.text = r.goal.text.string
            if let meta = r.meta {
                v.meta.isHidden = false
                v.meta.frame = r.metaFrame
                v.meta.font = d.font
                v.meta.text = meta.text.string
            } else {
                v.meta.isHidden = true
            }
            if let frame = r.timerFrame {
                v.timer.isHidden = false
                v.timer.frame = frame
                v.timer.font = tabular
                // The clock this row view already ran only if it's the same card (a reused cell had another's).
                v.startedAt = r.startedAt ?? (sameRow ? v.startedAt : nil) ?? Date().timeIntervalSince1970
                v.tick()
            } else {
                v.timer.isHidden = true
                v.startedAt = nil
            }
            v.agent.frame = r.agentFrame
            v.ticker.frame = r.activityFrame
            v.ticker.font = d.activityFont
            v.ticker.color = ChatPalette.label2
            v.ticker.isHidden = r.activityFrame.height == 0
            v.ticker.set(r.activity ?? (live ? "Waiting for activity" : nil), animated: sameRow)
            Shimmer.set(live, on: v.ticker, font: d.activityFont, contentToken: v.ticker.drawGeneration)
            v.accessibilityLabel = r.accessibility
            v.accessibilityTraits = live ? .updatesFrequently : .staticText
        }
        if anyLive {
            ActivityClock.shared.subscribe(self) { [weak self] in self?.rowViews.forEach { $0.tick() } }
            GlyphTicker.shared.setNeedsUpdate()      // a cell back from the reuse pool shows its spinners again
        } else {
            ActivityClock.shared.unsubscribe(self)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = ""
        ActivityClock.shared.unsubscribe(self)
    }
}

// MARK: - Generated image (§11.3)

final class ImageCardCell: ChatBaseCell {
    static let reuse = "activity.image"
    private let frameView = UIView()
    private let picture = UIImageView()
    private let placeholder = UIView()
    private let link = UIButton(type: .system)
    private var path: String?
    private var loadTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        frameView.layer.cornerRadius = HQShape.radius(18, .card)
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.backgroundColor = ChatPalette.fill4
        frameView.addSubview(placeholder)
        picture.contentMode = .scaleAspectFill
        picture.alpha = 0
        frameView.addSubview(picture)
        contentView.addSubview(frameView)
        link.contentHorizontalAlignment = .leading
        link.titleLabel?.numberOfLines = 1
        link.titleLabel?.lineBreakMode = .byTruncatingMiddle
        link.isHidden = true
        link.accessibilityIdentifier = "chat.generated-image.link"
        link.addTarget(self, action: #selector(retry), for: .touchUpInside)
        contentView.addSubview(link)
        let tap = UITapGestureRecognizer(target: self, action: #selector(open))
        frameView.addGestureRecognizer(tap)
        frameView.isAccessibilityElement = true
        accessibilityIdentifier = "chat.generated-image"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var maxPixel: Int {
        Int(max(frameView.bounds.width, frameView.bounds.height) * max(traitCollection.displayScale, 2))
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.image(let i)) = layout.content else { return }
        if i.failed {
            // The frame collapsed to its link row (the row is 44 pt tall now): tap tries again. The cancelled load
            // returns without clearing itself, so clear it here, or the retried row never loads again.
            loadTask?.cancel()
            loadTask = nil
            path = i.path
            frameView.isHidden = true
            link.isHidden = false
            link.frame = i.frame
            link.setTitle("Open image: \((i.path.map { ($0 as NSString).lastPathComponent }) ?? "image")", for: .normal)
            return
        }
        link.isHidden = true
        frameView.isHidden = false
        frameView.frame = i.frame
        picture.frame = frameView.bounds
        placeholder.frame = frameView.bounds
        frameView.accessibilityLabel = i.running ? "Rendering image" : "Generated image"
        frameView.accessibilityTraits = i.running ? .updatesFrequently : .image
        placeholder.backgroundColor = ChatPalette.fill3
        if i.path != path || (picture.image == nil && loadTask == nil) {
            path = i.path
            loadTask?.cancel()
            loadTask = nil
            picture.image = nil
            picture.alpha = 0
            // Drawn before (a reused cell, a reopened chat): straight from the small cache, no fade, no download.
            if let p = i.path, let cached = ActivityMedia.cachedThumbnail(path: p, maxPixel: maxPixel) {
                picture.image = cached
                picture.alpha = 1
            } else {
                load()
            }
        }
        Shimmer.set(i.running || picture.image == nil, on: placeholder)
    }

    private func load() {
        loadTask?.cancel()
        guard let path, let delegate = delegate as? ActivityCellDelegate else { return }
        let maxPixel = self.maxPixel
        loadTask = Task { [weak self] in
            do {
                let image = try await delegate.activityCellLoadImage(path: path, maxPixel: maxPixel)
                guard let self, !Task.isCancelled, self.path == path else { return }
                self.loadTask = nil
                self.picture.image = image
                Shimmer.set(false, on: self.placeholder)
                UIView.animate(withDuration: HQMotion.reduced ? 0 : 0.2) { self.picture.alpha = 1 }
            } catch {
                guard let self, !Task.isCancelled, self.path == path else { return }
                self.loadTask = nil
                // A good path that wouldn't load: the row collapses to the link line (§11.3).
                delegate.activityCellImageFailed(rowId: self.rowId, path: path, retry: false)
            }
        }
    }

    @objc private func retry() {
        guard let path else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellImageFailed(rowId: rowId, path: path, retry: true)
    }

    @objc private func open() {
        guard let image = picture.image, let path else { return }
        (delegate as? ActivityCellDelegate)?.activityCellOpenImage(image, path: path, from: frameView)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        path = nil
        picture.image = nil
        picture.alpha = 0
    }
}

// MARK: - Changed files (§12, n20 F10)

/// "N files changed" under a settled reply, one filled card: "Review" opens the chat's Changes page, a row per file
/// opens its text, held for Copy Path / Review in Changes; "Show All N Files" past five is the row's own expand
/// (`chatCellToggle`).
final class ChangedFilesCell: ChatBaseCell {
    static let reuse = "activity.changedFiles"

    /// The whole strip is the tap target for Review (as `TableFooterControl`'s row is for Expand).
    private final class HeaderView: UIControl {
        let title = UILabel()
        let review = UILabel()
        let chevron = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            title.textColor = ChatPalette.label2
            title.lineBreakMode = .byTruncatingTail
            review.textColor = ChatPalette.tintText
            chevron.tintColor = ChatPalette.tintText
            chevron.contentMode = .center
            for v: UIView in [title, review, chevron] { v.isUserInteractionEnabled = false; addSubview(v) }
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }   // motion-ok: colour only
    }

    /// One changed file: a row of the card under a hairline rule (as an opened One Line card's step), its own tap and
    /// hold menu.
    private final class FileLineView: UIControl {
        let rule = UIView()
        let glyph = UIImageView()
        let name = UILabel()
        let stats = UILabel()
        var path = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            rule.backgroundColor = ChatPalette.separator
            addSubview(rule)
            glyph.contentMode = .scaleAspectFit
            name.lineBreakMode = .byTruncatingMiddle
            name.textColor = ChatPalette.label
            stats.textAlignment = .right
            for v: UIView in [rule, glyph, name, stats] { v.isUserInteractionEnabled = false; addSubview(v) }
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }   // motion-ok: colour only
    }

    private let card = UIView()
    private let header = HeaderView()
    private let showAll = UIControl()
    private let showAllLabel = UILabel()
    private let showAllRule = UIView()
    private var lineViews: [FileLineView] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        contentView.addSubview(card)
        header.addTarget(self, action: #selector(reviewTapped), for: .touchUpInside)
        contentView.addSubview(header)
        showAllRule.backgroundColor = ChatPalette.separator
        showAllRule.isUserInteractionEnabled = false
        showAll.addSubview(showAllRule)
        showAllLabel.isUserInteractionEnabled = false
        showAll.addSubview(showAllLabel)
        showAll.addTarget(self, action: #selector(showAllTapped), for: .touchUpInside)
        showAll.isAccessibilityElement = true
        showAll.accessibilityTraits = .button
        showAllLabel.textColor = ChatPalette.tintText
        contentView.addSubview(showAll)
        accessibilityIdentifier = "chat.changed-files"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ChangedFilesCell, _) in
            view.card.backgroundColor = Self.contentCardFill
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.changedFiles(let c)) = layout.content else { return }
        card.frame = c.cardFrame
        card.backgroundColor = Self.contentCardFill   // [backdrop]
        let hairline = 1 / max(traitCollection.displayScale, 1)
        header.frame = c.headerFrame
        header.title.font = c.font
        header.title.text = c.headerTitle
        // The title's own size (already scaled), held at 20 pt × UI Scale: `scaled` put the scale and the text size on
        // a second time, and "Review" came out a size bigger than the title beside it (Mac polish #71).
        let reviewFont = HQFont.face(ofSize: min(c.font.pointSize, HQFont.scaled(20)), weight: .semibold)
        header.review.font = reviewFont
        header.review.text = "Review"
        header.chevron.image = UIImage(systemName: "chevron.forward",
                                       withConfiguration: UIImage.SymbolConfiguration(font: reviewFont, scale: .small))
        header.accessibilityLabel = c.headerTitle
        header.accessibilityValue = "Review"
        layoutHeader()

        while lineViews.count < c.rows.count {
            let v = FileLineView()
            v.addTarget(self, action: #selector(fileTapped(_:)), for: .touchUpInside)
            v.addInteraction(UIContextMenuInteraction(delegate: self))
            contentView.insertSubview(v, belowSubview: showAll)
            lineViews.append(v)
        }
        for (i, v) in lineViews.enumerated() {
            guard i < c.rows.count else { v.isHidden = true; continue }
            let r = c.rows[i]
            v.isHidden = false
            v.frame = r.frame
            v.rule.frame = CGRect(x: 12, y: 0, width: max(0, r.frame.width - 24), height: hairline)
            v.path = r.path
            let origin = r.frame.origin
            v.glyph.image = UIImage(systemName: r.glyph, withConfiguration: UIImage.SymbolConfiguration(font: c.font, scale: .medium))
            v.glyph.tintColor = r.glyphColor
            v.glyph.frame = r.glyphFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.name.font = c.font
            v.name.text = r.name
            v.name.frame = r.nameFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.stats.attributedText = r.stats
            v.stats.frame = r.statsFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.accessibilityLabel = r.accessibility
        }
        if let frame = c.showAllFrame, let title = c.showAllTitle {
            showAll.isHidden = false
            showAll.frame = frame
            showAllLabel.font = c.font
            showAllLabel.text = title
            showAllLabel.textAlignment = .natural
            showAllLabel.frame = showAll.bounds.insetBy(dx: 12, dy: 0)
            showAllRule.frame = CGRect(x: 12, y: 0, width: max(0, frame.width - 24), height: hairline)
            showAll.accessibilityLabel = title
        } else {
            showAll.isHidden = true
        }
    }

    private func layoutHeader() {
        let titleSize = header.title.sizeThatFits(header.bounds.size)
        let chevronSize = header.chevron.image?.size ?? .zero
        let reviewSize = header.review.sizeThatFits(header.bounds.size)
        header.chevron.frame = CGRect(x: header.bounds.width - ceil(chevronSize.width),
                                      y: (header.bounds.height - ceil(chevronSize.height)) / 2,
                                      width: ceil(chevronSize.width), height: ceil(chevronSize.height))
        header.review.frame = CGRect(x: header.chevron.frame.minX - 4 - ceil(reviewSize.width),
                                     y: (header.bounds.height - ceil(reviewSize.height)) / 2,
                                     width: ceil(reviewSize.width), height: ceil(reviewSize.height))
        let titleW = max(0, header.review.frame.minX - 8)
        header.title.frame = CGRect(x: 0, y: (header.bounds.height - ceil(titleSize.height)) / 2,
                                    width: min(ceil(titleSize.width), titleW), height: ceil(titleSize.height))
    }

    @objc private func reviewTapped() {
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellReviewChanges(highlighting: nil)
    }

    @objc private func fileTapped(_ sender: UIControl) {
        guard let v = sender as? FileLineView, !v.path.isEmpty else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenFile(path: v.path)
    }

    @objc private func showAllTapped() {
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for v in lineViews { v.path = "" }
    }
}

extension ChangedFilesCell: UIContextMenuInteractionDelegate {
    /// Held on a file row: Review in Changes (this file highlighted) and Copy Path.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let v = interaction.view as? FileLineView, !v.path.isEmpty else { return nil }
        let path = v.path
        let review = UIAction(title: "Review in Changes", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
            (self?.delegate as? ActivityCellDelegate)?.activityCellReviewChanges(highlighting: path)
        }
        let copy = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak v] _ in
            UIPasteboard.general.string = path
            Haptics.play(.success)
            MenusHUD.show("Copied", in: v?.window)
        }
        let menu = UIMenu(children: [review, copy])
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

// MARK: - Diff preview (§12, n20 F10)

/// A landed edit's first changed lines (Rows, Bubbles only — §12 DECISION), under its own row: a bordered card with
/// the file's name and +/− header, the washed lines (as the Changes page's own diff), and "Show all changes" when the
/// diff ran longer than the preview — the same step sheet a tool bubble's line opens.
final class DiffPreviewCell: ChatBaseCell {
    static let reuse = "activity.diffPreview"
    private let card = UIView()
    private let header = TextDrawView()
    private let body = TextDrawView()
    private let more = UIControl()
    private let moreText = TextDrawView()
    private var call: ToolCall?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        contentView.addSubview(card)
        card.addSubview(header)
        card.addSubview(body)
        more.addSubview(moreText)
        more.addTarget(self, action: #selector(showAll), for: .touchUpInside)
        more.isAccessibilityElement = true
        more.accessibilityTraits = .button
        card.addSubview(more)
        accessibilityIdentifier = "chat.diff-preview"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: DiffPreviewCell, _) in
            view.card.backgroundColor = Self.contentCardFill
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.diffPreview(let d)) = layout.content, case .activity(.diffPreview(let spec)) = row.kind else { return }
        call = spec.call
        card.backgroundColor = Self.contentCardFill   // [backdrop]
        card.frame = d.frame
        header.frame = d.headerFrame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        header.set(d.header, width: header.frame.width)
        body.frame = d.textFrame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        body.set(layout: d.text)
        if let frame = d.moreFrame, let text = d.moreText {
            more.isHidden = false
            let local = frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
            more.frame = CGRect(x: 0, y: local.minY - max(0, (44 - local.height) / 2), width: card.bounds.width, height: max(44, local.height))
            moreText.frame = CGRect(x: local.minX, y: local.minY - more.frame.minY, width: local.width, height: local.height)
            moreText.set(layout: text)
            more.accessibilityLabel = text.text.string
        } else {
            more.isHidden = true
        }
        accessibilityLabel = "\(spec.path), " + MoreWorkspaceRoot.counts(added: spec.added, removed: spec.removed)
    }

    @objc private func showAll() {
        guard let call else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenStep(rowId: rowId, call: call)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        call = nil
    }
}

// MARK: - Media seam (the attachments stream's `MediaLoader` / `MediaViewer` replace these at integration)

enum ActivityMedia {
    /// `GET /api/fs/download?path=&profile=&session_id=` (spec 03 §6.6), decoded to a thumbnail at `maxPixel` off the
    /// main thread. [load-cache] An absolute path goes through the chat's media cache (`MediaLoader.image(path:…)`:
    /// Caches/HQNMedia, kept across launches and shared with the viewer, so a reopened chat or Steps sheet doesn't
    /// download it again); a session-relative one is read directly, as the cache's key doesn't carry its session.
    static var loadImage: (_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?, _ maxPixel: Int)
        async throws -> UIImage = { client, path, profile, sessionId, maxPixel in
            try await thumbnail(client, path, profile, sessionId, maxPixel)
        }

    /// The whole picture, not the frame's thumbnail (the viewer's zoom and Save): the bytes decoded at full size off
    /// the main thread. [load-cache] From the media cache, as `loadImage`.
    static var loadFull: (_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?)
        async throws -> UIImage = { client, path, profile, sessionId in
            try await full(client, path, profile, sessionId)
        }

    @concurrent private static func thumbnail(_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?,
                                              _ maxPixel: Int) async throws -> UIImage {
        if !MediaLoader.isRelative(path) {
            do {
                return try await MediaLoader.image(path: path, profile: profile, sessionId: sessionId, accountId: client.account.id,
                                                   maxPixel: maxPixel)
            } catch MediaLoadError.unavailable {}   // no media pipeline for this account: read it directly
        }
        return try await decodeThumbnail(try await download(client, path, profile, sessionId), maxPixel: maxPixel)
    }

    @concurrent private static func full(_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?) async throws -> UIImage {
        if !MediaLoader.isRelative(path) {
            do {
                let url = try await MediaLoader.original(path: path, profile: profile, sessionId: sessionId, accountId: client.account.id)
                return try await decodeFull(contentsOf: url)
            } catch MediaLoadError.unavailable {}
        }
        return try await loadFullDirect(client, path, profile, sessionId)
    }

    /// [load-cache] The whole picture read past the media cache: the Screen's live screenshot feed, whose pictures are
    /// each shown once and would only push chat pictures out of the cache.
    @concurrent static func loadFullDirect(_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?) async throws -> UIImage {
        try await decodeFull(try await download(client, path, profile, sessionId))
    }

    @concurrent private static func download(_ client: any GatewayClient, _ path: String, _ profile: String, _ sessionId: String?) async throws -> Data {
        var query = [URLQueryItem(name: "path", value: path)]
        if !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let sessionId, !path.hasPrefix("/") { query.append(URLQueryItem(name: "session_id", value: sessionId)) }
        return try await client.rest("GET", "/api/fs/download", query: query, body: nil)
    }

    /// Opens a card's picture full screen (spec §11.3). A gateway file with an absolute path opens in the chat's photo
    /// viewer (`MediaViewer.present`: swipe down to close, Share, Save to Photos, a full size that didn't load says so),
    /// its preview the thumbnail the card already drew. A session-relative path (the media cache's key doesn't carry
    /// its session) and an inline screenshot open in `ActivityImageViewer`: the thumbnail at once, the whole picture
    /// once it has loaded.
    static func present(from: UIView, image: UIImage, path: String, context: MediaContext?, loadFull: (() async throws -> UIImage)?) {
        if let context, Self.opensInPhotoViewer(path: path),
           AttachmentCenter.existing(context.accountId)?.client is GatewayFileTransfers {
            let name = MediaKinds.name(ofPath: path, image: true)
            let ref = MediaRef(kind: .image, attachment: MessageAttachment(kind: .image, source: .gateway(path: path), name: name), label: name)
            MediaViewer.present(from: from, items: [ref], index: 0, context: context)
            return
        }
        guard let root = from.window?.rootViewController else { return }
        ActivityImageViewer.present(from: topmost(root), source: from, image: image, name: (path as NSString).lastPathComponent, loadFull: loadFull)
    }

    /// An absolute gateway path (not a `data:` picture): the media cache keys it by account, profile and path alone.
    nonisolated static func opensInPhotoViewer(path: String) -> Bool {
        !path.isEmpty && !path.lowercased().hasPrefix("data:") && !MediaLoader.isRelative(path)
    }

    /// Thumbnails already drawn, by path and size (a reused cell or a reopened chat draws without a download).
    private static let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    static func cachedThumbnail(path: String, maxPixel: Int) -> UIImage? { thumbnails.object(forKey: "\(maxPixel)|\(path)" as NSString) }

    static func keepThumbnail(_ image: UIImage, path: String, maxPixel: Int) {
        thumbnails.setObject(image, forKey: "\(maxPixel)|\(path)" as NSString)
    }

    private static func topmost(_ vc: UIViewController) -> UIViewController {
        var top = vc
        while let next = top.presentedViewController { top = next }
        return top
    }

    /// [load-cache] A cached original read and decoded off the main thread.
    @concurrent static func decodeFull(contentsOf url: URL) async throws -> UIImage {
        try await decodeFull(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    @concurrent static func decodeFull(_ data: Data) async throws -> UIImage {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return image.preparingForDisplay() ?? image
    }

    @concurrent static func decodeThumbnail(_ data: Data, maxPixel: Int) async throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel), kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage: cg)
    }
}

/// The viewer for a picture the photo viewer can't key (a session-relative path, an inline screenshot): the picture on
/// black under the photo viewer's own bars (Close on top, Share below, dark so they read on the black page in either
/// look), pinch to zoom, swipe down to close at the fitted size, and a caption when the whole picture didn't load.
final class ActivityImageViewer: UIViewController, UIScrollViewDelegate {
    private var image: UIImage
    private let name: String
    private let loadFull: (() async throws -> UIImage)?
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var fullTask: Task<Void, Never>?
    private var shareItem: UIBarButtonItem!
    private var failedCaption: UIButton?

    /// Presents the viewer over `presenter`, zooming from `source` (the card's picture).
    static func present(from presenter: UIViewController, source: UIView, image: UIImage, name: String, loadFull: (() async throws -> UIImage)?) {
        let viewer = ActivityImageViewer(image: image, name: name, loadFull: loadFull)
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark          // bars and buttons read on the black page
        nav.setToolbarHidden(false, animated: false)
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.isAtMinimumZoom ?? true }
        nav.preferredTransition = .zoom(options: options) { [weak source] _ in source }
        presenter.present(nav, animated: true)
    }

    init(image: UIImage, name: String, loadFull: (() async throws -> UIImage)? = nil) {
        self.image = image
        self.name = name
        self.loadFull = loadFull
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit { fullTask?.cancel() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isAtMinimumZoom: Bool { scroll.zoomScale <= scroll.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        scroll.delegate = self
        scroll.maximumZoomScale = 4
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        view.addSubview(scroll)
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "viewer.close"
        navigationItem.hqPlaceClose(close)
        // The share sheet offers Save Image too; it is named for what it opens.
        shareItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })
        shareItem.accessibilityLabel = "Share"
        toolbarItems = [shareItem, .flexibleSpace()]
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = name
        imageView.accessibilityTraits = .image
        loadWhole()
    }

    /// VoiceOver's two-finger scrub closes the viewer, as Close does.
    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func share() {
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        // [m9/ipad] On iPad a share sheet is a popover and needs its anchor (it crashes without one).
        share.popoverPresentationController?.barButtonItem = shareItem
        present(share, animated: true)
    }

    /// The frame's thumbnail shows at once; the whole picture replaces it (zoom and Share get every pixel).
    private func loadWhole() {
        guard let loadFull else { return }
        showFailure(false)
        fullTask?.cancel()
        fullTask = Task { [weak self] in
            do {
                let full = try await loadFull()
                guard let self, !Task.isCancelled else { return }
                self.image = full
                self.imageView.image = full
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                AppLog.note("chatui", "activity picture: the full size didn't load (\(type(of: error))), kept the preview")
                self.showFailure(true)
            }
        }
    }

    /// Over the preview when the whole picture didn't load, as the photo viewer shows it; a tap tries again.
    private func showFailure(_ failed: Bool) {
        failedCaption?.removeFromSuperview()
        failedCaption = nil
        guard failed else { return }
        var config = UIButton.Configuration.hqGlass()
        config.title = "Showing a Preview"
        config.subtitle = MediaLoadError.unreachable.fileMessage
        config.image = UIImage(systemName: "arrow.clockwise")
        config.imagePadding = 8
        config.titleAlignment = .leading
        let caption = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.loadWhole() })
        caption.accessibilityHint = "Tries to load the full-size picture again"
        caption.titleLabel?.numberOfLines = 0
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        failedCaption = caption
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

// MARK: - Added to Tasks ([tasks], mockup 4-chat)

/// "Added to Tasks" under a reply whose bot put tasks on your list: a row per task (its sheet on the Tasks page),
/// Open Tasks, and Undo (the tasks are deleted; the card then reads "Removed from Tasks").
final class TasksAddedCell: ChatBaseCell {
    static let reuse = "activity.tasksAdded"

    /// [tasks] A together task's step: a mark, "Hermes: Rank the 167…", and "Started" at the right.
    private final class StepView {
        let mark = UIImageView()
        let words = UILabel()
        let status = UILabel()
        init(in parent: UIView) {
            mark.contentMode = .scaleAspectFit
            words.lineBreakMode = .byTruncatingTail
            for v: UIView in [mark, words, status] { v.isUserInteractionEnabled = false; parent.addSubview(v) }
        }
        var hidden: Bool = false { didSet { for v: UIView in [mark, words, status] { v.isHidden = hidden } } }
    }

    private final class LineView: UIControl {
        let rule = UIView()
        let circle = UIImageView()
        let title = UILabel()
        let detail = UILabel()
        let more = UILabel()
        var stepViews: [StepView] = []
        var taskId = ""

        override init(frame: CGRect) {
            super.init(frame: frame)
            rule.backgroundColor = ChatPalette.separator
            circle.contentMode = .scaleAspectFit
            circle.tintColor = ChatPalette.label3
            title.textColor = ChatPalette.label
            title.lineBreakMode = .byTruncatingTail
            detail.textColor = ChatPalette.label2
            detail.lineBreakMode = .byTruncatingTail
            more.textColor = ChatPalette.label2
            for v: UIView in [rule, circle, title, detail, more] { v.isUserInteractionEnabled = false; addSubview(v) }
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }   // motion-ok: colour only
    }

    private let card = UIView()
    private let badge = UIImageView()
    private let header = UILabel()
    private let footerRule = UIView()
    private let openButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let helpRule = UIView()
    private let helpButton = UIButton(type: .system)
    private var lineViews: [LineView] = []
    private var ids: [String] = []
    private var titles: [String] = []
    private var undone = false
    private var helping = false
    private var botName = "Hermes"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        contentView.addSubview(card)
        badge.contentMode = .scaleAspectFit
        for v: UIView in [badge, header] { v.isUserInteractionEnabled = false; contentView.addSubview(v) }
        footerRule.backgroundColor = ChatPalette.separator
        footerRule.isUserInteractionEnabled = false
        contentView.addSubview(footerRule)
        openButton.contentHorizontalAlignment = .leading
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.accessibilityIdentifier = "chat.tasks.open"
        undoButton.contentHorizontalAlignment = .trailing
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        undoButton.accessibilityIdentifier = "chat.tasks.undo"
        contentView.addSubview(openButton)
        contentView.addSubview(undoButton)
        helpRule.backgroundColor = ChatPalette.separator
        helpRule.isUserInteractionEnabled = false
        contentView.addSubview(helpRule)
        helpButton.contentHorizontalAlignment = .leading
        helpButton.addTarget(self, action: #selector(helpTapped), for: .touchUpInside)
        helpButton.accessibilityIdentifier = "chat.tasks.help"
        contentView.addSubview(helpButton)
        accessibilityIdentifier = "chat.tasks-added"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TasksAddedCell, _) in
            view.card.backgroundColor = Self.contentCardFill
            view.paintHeader()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Ready green as words (iOS's own green is 2.2:1 on white).
    private static let green = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            : UIColor(red: 0.11, green: 0.50, blue: 0.22, alpha: 1)
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.tasksAdded(let t)) = layout.content else { return }
        card.frame = t.cardFrame
        card.backgroundColor = Self.contentCardFill   // [backdrop]
        let hairline = 1 / max(traitCollection.displayScale, 1)
        undone = t.undone
        helping = t.helping
        botName = t.botName
        ids = t.lines.map(\.id)
        titles = t.lines.map(\.title)
        let headFont = HQFont.face(ofSize: t.font.pointSize, weight: .semibold)
        header.font = headFont
        let badgeSize = ceil(headFont.pointSize * 1.15)
        badge.frame = CGRect(x: t.headerFrame.minX, y: t.headerFrame.midY - badgeSize / 2, width: badgeSize, height: badgeSize)
        header.frame = CGRect(x: badge.frame.maxX + 8, y: t.headerFrame.minY, width: t.headerFrame.width - badgeSize - 8,
                              height: t.headerFrame.height)
        paintHeader()

        while lineViews.count < t.lines.count {
            let v = LineView()
            v.addTarget(self, action: #selector(lineTapped(_:)), for: .touchUpInside)
            contentView.insertSubview(v, belowSubview: openButton)
            lineViews.append(v)
        }
        for (i, v) in lineViews.enumerated() {
            guard i < t.lines.count else { v.isHidden = true; continue }
            let line = t.lines[i]
            v.isHidden = false
            v.frame = line.frame
            v.taskId = line.id
            let origin = line.frame.origin
            v.rule.frame = CGRect(x: 14, y: 0, width: max(0, line.frame.width - 28), height: hairline)
            v.rule.isHidden = i == 0
            v.circle.image = UIImage(systemName: "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: line.circleFrame.height, weight: .light))
            v.circle.frame = line.circleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.title.font = t.font
            v.title.attributedText = NSAttributedString(string: line.title, attributes: undone
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2] : [.foregroundColor: ChatPalette.label])
            v.title.frame = line.titleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            v.detail.font = t.detailFont
            v.detail.text = line.detail
            v.detail.frame = line.detailFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            layoutSteps(line, in: v, font: t.detailFont)
            v.isEnabled = !undone
            v.accessibilityLabel = ([line.title, line.detail] + line.steps.map { [$0.step.text, $0.step.status].filter { !$0.isEmpty }.joined(separator: ", ") })
                .filter { !$0.isEmpty }.joined(separator: ", ")
            v.accessibilityIdentifier = "chat.tasks.row.\(i)"
        }
        if let help = t.helpFrame {
            helpRule.isHidden = false
            helpButton.isHidden = false
            helpRule.frame = CGRect(x: help.minX + 14, y: help.minY, width: max(0, help.width - 28), height: hairline)
            helpButton.frame = CGRect(x: help.minX + 14, y: help.minY, width: help.width - 28, height: help.height)
            var config = UIButton.Configuration.plain()
            config.contentInsets = .zero
            config.imagePadding = 8
            config.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(font: t.font))
            config.attributedTitle = AttributedString("Ask \(botName) to Help", attributes: AttributeContainer([.font: t.font]))
            config.baseForegroundColor = ChatPalette.tintText
            helpButton.configuration = config
            helpButton.accessibilityLabel = "Ask \(botName) to Help"
        } else {
            helpRule.isHidden = true
            helpButton.isHidden = true
        }
        footerRule.frame = CGRect(x: t.footerFrame.minX + 14, y: t.footerFrame.minY, width: max(0, t.footerFrame.width - 28), height: hairline)
        let half = t.footerFrame.width / 2
        openButton.frame = CGRect(x: t.footerFrame.minX + 14, y: t.footerFrame.minY, width: half - 14, height: t.footerFrame.height)
        undoButton.frame = CGRect(x: t.footerFrame.minX + half, y: t.footerFrame.minY, width: half - 14, height: t.footerFrame.height)
        setButton(openButton, "Open Tasks", font: t.font)
        setButton(undoButton, "Undo", font: t.font)
        undoButton.isHidden = undone || helping
    }

    /// [tasks] The steps under a together task: yours a plain circle, the bot's a half-filled one (a tick once done),
    /// its first open one with "Started" or "Ahead of time" at the right.
    private func layoutSteps(_ line: TasksAddedLayout.Line, in v: LineView, font: UIFont) {
        while v.stepViews.count < line.steps.count { v.stepViews.append(StepView(in: v)) }
        for (i, sv) in v.stepViews.enumerated() {
            guard i < line.steps.count else { sv.hidden = true; continue }
            let step = line.steps[i]
            sv.hidden = false
            let symbol = step.step.done ? "checkmark.circle.fill" : step.step.mine ? "circle" : "circle.lefthalf.filled"
            sv.mark.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: step.markFrame.height, weight: .regular))
            sv.mark.tintColor = step.step.done ? Self.green : step.step.mine ? ChatPalette.label3 : ChatPalette.tintText
            sv.mark.frame = step.markFrame
            sv.words.font = font
            sv.words.textColor = step.step.done ? ChatPalette.label2 : ChatPalette.label
            sv.words.attributedText = NSAttributedString(string: step.step.text, attributes: step.step.done
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2]
                : [.foregroundColor: ChatPalette.label])
            sv.words.frame = step.textFrame
            sv.status.font = HQFont.face(ofSize: font.pointSize, weight: .semibold)
            sv.status.textColor = ChatPalette.tintText
            sv.status.text = step.step.status
            sv.status.frame = step.statusFrame
        }
        if let more = line.moreFrame {
            v.more.isHidden = false
            v.more.font = font
            v.more.text = line.more == 1 ? "+1 more step" : "+\(line.more) more steps"
            v.more.frame = more
        } else {
            v.more.isHidden = true
        }
    }

    private func setButton(_ button: UIButton, _ title: String, font: UIFont) {
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText]), for: .normal)
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText.withAlphaComponent(0.5)]), for: .highlighted)
    }

    private func paintHeader() {
        let color = undone ? ChatPalette.label2 : Self.green
        header.text = undone ? "Removed from Tasks" : helping ? "\(botName) Is Helping" : "Added to Tasks"
        header.textColor = color
        badge.image = UIImage(systemName: undone ? "arrow.uturn.backward.circle.fill" : "checkmark.square.fill")
        badge.tintColor = color
        header.accessibilityTraits = .header
    }

    @objc private func lineTapped(_ sender: UIControl) {
        guard let v = sender as? LineView, !v.taskId.isEmpty, !undone else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenTask(id: v.taskId)
    }

    @objc private func helpTapped() {
        guard let id = ids.first, let title = titles.first, !undone else { return }
        Haptics.play(.light)   // as Send: it asks the bot (.soft was too faint to feel, owner 2026-11-04)
        helpButton.isEnabled = false
        (delegate as? ActivityCellDelegate)?.activityCellAskHelp(taskId: id, title: title)
    }

    @objc private func openTapped() {
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenTask(id: nil)
    }

    @objc private func undoTapped() {
        guard !undone, !ids.isEmpty else { return }
        Haptics.play(.light)   // at the tap; success (or error) follows once the gateway answers
        undoButton.isEnabled = false
        let taken = ids
        (delegate as? ActivityCellDelegate)?.activityCellUndoTasks(ids: taken) { [weak self] ok in
            guard let self else { return }
            self.undoButton.isEnabled = true
            guard ok else { Haptics.play(.error); return }
            Haptics.play(.success)
            TodoUndone.add(taken)
            guard self.ids == taken else { return }
            self.undone = true
            self.undoButton.isHidden = true
            self.paintHeader()
            for v in self.lineViews where !v.isHidden {
                v.isEnabled = false
                v.title.attributedText = NSAttributedString(string: v.title.text ?? "", attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2, .font: v.title.font as Any])
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for v in lineViews { v.taskId = "" }
        ids = []
        titles = []
        undoButton.isEnabled = true
        helpButton.isEnabled = true
    }
}
