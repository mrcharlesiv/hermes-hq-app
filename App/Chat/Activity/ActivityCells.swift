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
    /// [task-lists] A tap on a bot's offer (Make Work & Add 9, Not Now, Move 3 to Work, Undo); `done` says whether
    /// the gateway took it.
    func activityCellAnswerOffer(id: String, action: TodoOfferAction, list: Bool, done: @escaping (Bool) -> Void)
    /// [goals step 3] A tap on a goal's card (Use This Plan, Add to Goal, Just Tasks, Keep the Goal, No Plan, Undo).
    func activityCellAnswerGoalOffer(id: String, action: TodoOfferAction, plan: Bool, inGoal: Bool, done: @escaping (Bool) -> Void)
    /// [goals step 3] Change It / Change: the goal's chat takes the cursor (this chat, or the goal's own).
    func activityCellChangeGoalOffer(goal: String?)
    /// [goals step 3] "2 more ›": the whole card.
    func activityCellShowGoalOffer(id: String)
    /// [chat-mark-done] Mark Done, Keep Open or Undo on a bot's offer to close a task; `done` says whether the gateway
    /// took it.
    func activityCellCloseTask(id: String, action: TodoCloseCards.Action, done: @escaping (Bool) -> Void)
}

enum ActivityCells {
    static func register(in table: UITableView) {
        table.register(ToolBubbleCell.self, forCellReuseIdentifier: ToolBubbleCell.reuse)
        table.register(DelegateCardCell.self, forCellReuseIdentifier: DelegateCardCell.reuse)
        table.register(ImageCardCell.self, forCellReuseIdentifier: ImageCardCell.reuse)
        table.register(ChangedFilesCell.self, forCellReuseIdentifier: ChangedFilesCell.reuse)
        table.register(DiffPreviewCell.self, forCellReuseIdentifier: DiffPreviewCell.reuse)
        table.register(TasksAddedCell.self, forCellReuseIdentifier: TasksAddedCell.reuse)
        table.register(TasksOfferCell.self, forCellReuseIdentifier: TasksOfferCell.reuse)
        table.register(GoalOfferCell.self, forCellReuseIdentifier: GoalOfferCell.reuse)
        table.register(TaskCloseCell.self, forCellReuseIdentifier: TaskCloseCell.reuse)
    }

    static func reuse(for kind: ActivityRowKind) -> String {
        switch kind {
        case .toolBubble: return ToolBubbleCell.reuse
        case .delegate: return DelegateCardCell.reuse
        case .image: return ImageCardCell.reuse
        case .changedFiles: return ChangedFilesCell.reuse
        case .diffPreview: return DiffPreviewCell.reuse
        case .tasksAdded: return TasksAddedCell.reuse
        case .tasksOffer: return TasksOfferCell.reuse
        case .goalOffer: return GoalOfferCell.reuse
        case .taskClose: return TaskCloseCell.reuse
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
            border.lineWidth = max(HQShape.pixel(traitCollection.displayScale), 1)
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
                view.paintCard()
            }
        }

        func paintCard() {
            let width = max(HQShape.pixel(traitCollection.displayScale), 1)
            border.lineWidth = width
            border.fillColor = ChatPalette.promptCard.resolvedColor(with: traitCollection).cgColor
            border.strokeColor = ChatPalette.promptEdge.resolvedColor(with: traitCollection).cgColor
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
            let inset = max(HQShape.pixel(traitCollection.displayScale), 1) / 2
            v.border.path = UIBezierPath(roundedRect: v.bounds.insetBy(dx: inset, dy: inset), cornerRadius: HQShape.radius(18, .card)).cgPath
            v.paintCard()
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
            PointerEffects.surface(self)   // [mac] Feel list B: lit under the pointer, deeper while pressed
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.5) } }   // motion-ok: colour only
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
            PointerEffects.surface(self)   // [mac] Feel list B: lit under the pointer, deeper while pressed
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.5) } }   // motion-ok: colour only
    }

    /// [files] File Changes › Folded: the one line ("8 files changed +49 −11 ⌄"), drawn as an update group's centred
    /// line — glyph, words, a soft caret (down while shut, up while open) — its press area hugging them.
    private let lineButton = UIControl()
    private let lineGlyph = CAShapeLayer()
    private let lineLabel = UILabel()
    private let lineCaret = CAShapeLayer()
    private var lineGlyphSize: CGFloat = 0
    private let card = UIView()
    private let header = HeaderView()
    private let showAll = UIControl()
    private let showAllLabel = UILabel()
    private let showAllRule = UIView()
    private var lineViews: [FileLineView] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        for shape in [lineGlyph, lineCaret] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            lineButton.layer.addSublayer(shape)
        }
        lineGlyph.lineWidth = 1.5
        lineCaret.lineWidth = 1.3
        lineLabel.isUserInteractionEnabled = false
        lineLabel.lineBreakMode = .byTruncatingTail
        lineButton.addSubview(lineLabel)
        lineButton.layer.cornerRadius = 10
        lineButton.layer.cornerCurve = .continuous
        lineButton.addTarget(self, action: #selector(lineTapped), for: .touchUpInside)
        lineButton.addTarget(self, action: #selector(linePressed), for: [.touchDown, .touchDragEnter])
        lineButton.addTarget(self, action: #selector(lineReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        lineButton.isAccessibilityElement = true
        lineButton.accessibilityTraits = .button
        lineButton.accessibilityIdentifier = "chat.changed-files.line"
        PointerEffects.surface(lineButton, capsule: true)
        // [hover-shape] Over a chat background the line draws a frosted pill as tall as its words, inside its taller
        // row: the pointer's fill is that pill, not a capsule round the whole row.
        PointerEffects.outline(lineButton) { [weak self] in
            guard let self else { return nil }
            let box = lineButton.bounds
            guard let pill = backingFrame else { return PointerEffects.Outline(rect: box, radius: box.height / 2) }
            let rect = contentView.convert(pill, to: lineButton)
            return PointerEffects.Outline(rect: rect, radius: rect.height / 2)
        }
        contentView.addSubview(lineButton)
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
        PointerEffects.surface(showAll)   // [mac] Feel list B: lit under the pointer, as the file rows above it
        showAll.isAccessibilityElement = true
        showAll.accessibilityTraits = .button
        showAllLabel.textColor = ChatPalette.tintText
        contentView.addSubview(showAll)
        accessibilityIdentifier = "chat.changed-files"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ChangedFilesCell, _) in
            view.styleChatCard(view.card)
            view.lineColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.changedFiles(let c)) = layout.content else { return }
        configureLine(c)
        let showsCard = c.cardShown
        card.isHidden = !showsCard
        header.isHidden = !showsCard
        if !showsCard {
            for v in lineViews { v.isHidden = true }
            showAll.isHidden = true
            return
        }
        card.frame = c.cardFrame
        styleChatCard(card)
        let hairline = HQShape.pixel(traitCollection.displayScale)
        header.frame = c.headerFrame
        PointerEffects.fit(header, card: c.cardFrame, radius: ChatMetrics.insetCardRadius)
        header.title.font = c.font
        // Folded and open: the line above already says how many files, so the card's top line is "Review ›" alone.
        header.title.text = c.lineFrame == nil ? c.headerTitle : nil
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
            PointerEffects.fit(v, card: c.cardFrame, radius: ChatMetrics.insetCardRadius)
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
            PointerEffects.fit(showAll, card: c.cardFrame, radius: ChatMetrics.insetCardRadius)
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

    /// [backdrop] On a chat picture's pill the words and glyph take the primary label, the caret label 2 (as a work line).
    private func lineColors() {
        let onPill = Backdrop.chats.shows
        lineGlyph.strokeColor = (onPill ? ChatPalette.label : ChatPalette.label2).resolvedColor(with: traitCollection).cgColor
        lineCaret.strokeColor = (onPill ? ChatPalette.label2 : ChatPalette.label3).resolvedColor(with: traitCollection).cgColor
    }

    /// [files] The folded line: glyph, words and caret centred together in the row (`ChatToolCell.layoutGroup`'s sizes).
    private func configureLine(_ c: ChangedFilesLayout) {
        guard let row = c.lineFrame, let text = c.lineText, let font = c.lineFont else {
            lineButton.isHidden = true
            placeBacking(nil, radius: 0)
            return
        }
        lineButton.isHidden = false
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        let words = NSMutableAttributedString(attributedString: text)
        if Backdrop.chats.shows {
            // [backdrop] Words on the pill in the primary label; the +/− keep their green and red.
            words.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: words.length)) { value, range, _ in
                if (value as? UIColor) == ChatPalette.label2 { words.addAttribute(.foregroundColor, value: ChatPalette.label, range: range) }
            }
        }
        lineLabel.attributedText = words
        let side = (style.toolGlyph - 2).rounded()
        let pad: CGFloat = 10, glyphGap: CGFloat = 6
        let caretW = max(7, font.capHeight.rounded())
        let caretGap = max(5, (caretW * 0.5).rounded())
        let room = max(0, row.width - 2 * pad - side - glyphGap - caretGap - caretW)
        let textW = min(ceil(words.size().width), room)
        let contentW = side + glyphGap + textW + caretGap + caretW
        let h = row.height
        lineButton.frame = CGRect(x: row.minX + ((row.width - contentW) / 2).rounded() - pad, y: row.minY,
                                  width: contentW + 2 * pad, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineGlyph.frame = CGRect(x: pad, y: ((h - side) / 2).rounded(), width: side, height: side)
        if lineGlyphSize != side {
            lineGlyph.path = ChatGlyph.file.path(size: side)
            lineGlyphSize = side
        }
        let caretH = (caretW * 0.5).rounded()
        let capMid = (h - font.lineHeight) / 2 + font.ascender - font.capHeight / 2
        lineCaret.frame = CGRect(x: pad + side + glyphGap + textW + caretGap, y: (capMid - caretH / 2).rounded(), width: caretW, height: caretH)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: c.opened ? caretH : 0))
        path.addLine(to: CGPoint(x: caretW / 2, y: c.opened ? 0 : caretH))
        path.addLine(to: CGPoint(x: caretW, y: c.opened ? caretH : 0))
        lineCaret.path = path.cgPath
        lineColors()
        CATransaction.commit()
        lineLabel.frame = CGRect(x: pad + side + glyphGap, y: 0, width: textW, height: h)
        lineButton.accessibilityLabel = words.string
        lineButton.accessibilityValue = c.opened ? "Expanded" : "Collapsed"
        // [backdrop] A capsule as tall as the words, as a work line's.
        let pillH = min(h, ceil(max(font.lineHeight, side)) + 8)
        placeBacking(lineButton.frame.insetBy(dx: 0, dy: ((h - pillH) / 2).rounded()), radius: pillH / 2)
        PointerEffects.outlineDidLayout(lineButton)
    }

    @objc private func linePressed() {
        if showsBacking { pressBacking(true) } else { lineButton.alpha = PointerEffects.dim(true, to: 0.5) }
    }

    @objc private func lineReleased() {
        pressBacking(false)
        lineButton.alpha = 1
    }

    @objc private func lineTapped() {
        Haptics.play(.selection)
        delegate?.chatCellToggleFiles(rowId: rowId)
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
            view.styleChatCard(view.card)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.diffPreview(let d)) = layout.content, case .activity(.diffPreview(let spec)) = row.kind else { return }
        call = spec.call
        styleChatCard(card)
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
    private var fling: PhotoFling?
    /// Owner 2026-11-22: press and hold (right-click on the Mac) on the picture: Save to Photos, Share…, Copy Image.
    private var imageMenu: ViewerImageMenu?

    /// Presents the viewer over `presenter`, zooming from `source` (the card's picture).
    static func present(from presenter: UIViewController, source: UIView, image: UIImage, name: String, loadFull: (() async throws -> UIImage)?) {
        let viewer = ActivityImageViewer(image: image, name: name, loadFull: loadFull)
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark          // bars and buttons read on the black page
        nav.setToolbarHidden(false, animated: false)
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak viewer] context in
            // A fling up is `PhotoFling`'s (the system's drag closes downward only).
            if context.velocity.dy < 0, abs(context.velocity.dy) > abs(context.velocity.dx) { return false }
            return viewer?.isAtMinimumZoom ?? true
        }
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
        fling = PhotoFling(host: self, directions: .up, flyOff: false, content: { [weak self] in self?.scroll },
                           canBegin: { [weak self] in self?.isAtMinimumZoom ?? true })
        let menu = ViewerImageMenu { [weak self] in
            guard let self else { return nil }
            let source = MediaSource.image({ [weak self] in self?.image ?? UIImage() }, name: self.name)
            return MediaActions.menu(for: source, from: self, anchor: self.imageView)
        }
        menu.attach(to: imageView)
        imageMenu = menu
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
            PointerEffects.surface(self)   // [mac] Feel list B: lit under the pointer, deeper while pressed
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.5) } }   // motion-ok: colour only
    }

    private let foldButton = UIControl()
    private let foldIcon = UIImageView()
    private let foldLabel = UILabel()
    private let foldChevron = UIImageView()
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
        foldButton.isHidden = true
        foldButton.isAccessibilityElement = true
        foldButton.accessibilityTraits = .button
        foldButton.accessibilityIdentifier = "chat.tasks.fold"
        foldButton.addTarget(self, action: #selector(foldTapped), for: .touchUpInside)
        foldIcon.contentMode = .scaleAspectFit
        foldIcon.isUserInteractionEnabled = false
        foldLabel.lineBreakMode = .byTruncatingTail
        foldLabel.isUserInteractionEnabled = false
        foldChevron.contentMode = .scaleAspectFit
        foldChevron.isUserInteractionEnabled = false
        foldButton.addSubview(foldIcon)
        foldButton.addSubview(foldLabel)
        foldButton.addSubview(foldChevron)
        contentView.addSubview(foldButton)
        PointerEffects.surface(foldButton, capsule: true)
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
            view.styleChatCard(view.card)
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
        configureFoldLine(t)
        let showsCard = t.cardShown
        for v: UIView in [card, badge, header, footerRule, openButton] { v.isHidden = !showsCard }
        if !showsCard {
            undoButton.isHidden = true
            helpRule.isHidden = true
            helpButton.isHidden = true
            for v in lineViews { v.isHidden = true }
            return
        }
        card.frame = t.cardFrame
        styleChatCard(card)
        let hairline = HQShape.pixel(traitCollection.displayScale)
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
            PointerEffects.fit(v, card: t.cardFrame, radius: ChatMetrics.insetCardRadius)
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

    private func configureFoldLine(_ t: TasksAddedLayout) {
        guard let row = t.lineFrame, let text = t.lineText, let font = t.lineFont else {
            foldButton.isHidden = true
            placeBacking(nil, radius: 0)
            return
        }
        foldButton.isHidden = false
        let onPill = Backdrop.chats.shows
        let words = NSMutableAttributedString(attributedString: text)
        if onPill {
            words.addAttribute(.foregroundColor, value: ChatPalette.label, range: NSRange(location: 0, length: words.length))
        }
        foldLabel.attributedText = words
        let iconSide = ceil(min(22, max(15, font.pointSize * 1.1)))
        let chevSide = ceil(min(18, max(11, font.pointSize * 0.85)))
        let padX: CGFloat = 8, iconGap: CGFloat = 7, chevGap: CGFloat = 6
        let room = max(40, row.width - iconSide - iconGap - chevGap - chevSide)
        let textW = min(ceil(words.size().width), room)
        let contentW = iconSide + iconGap + textW + chevGap + chevSide
        let tapH = max(44, row.height)
        foldButton.frame = CGRect(x: row.minX - padX, y: row.minY + ((row.height - tapH) / 2).rounded(),
                                  width: contentW + 2 * padX, height: tapH)
        let midY = tapH / 2
        foldIcon.frame = CGRect(x: padX, y: (midY - iconSide / 2).rounded(), width: iconSide, height: iconSide)
        let iconName = t.undone ? "arrow.uturn.backward.circle" : "checkmark.circle"
        foldIcon.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSide * 0.86, weight: .regular))
        foldIcon.tintColor = onPill ? ChatPalette.label : ChatPalette.label2
        let textH = ceil(font.lineHeight)
        foldLabel.frame = CGRect(x: padX + iconSide + iconGap, y: (midY - textH / 2).rounded(), width: textW, height: textH)
        foldChevron.frame = CGRect(x: foldLabel.frame.maxX + chevGap, y: (midY - chevSide / 2).rounded(), width: chevSide, height: chevSide)
        foldChevron.image = UIImage(systemName: t.opened ? "chevron.up" : "chevron.down",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: chevSide * 0.86, weight: .semibold))
        foldChevron.tintColor = onPill ? ChatPalette.label2 : ChatPalette.label3
        foldButton.accessibilityLabel = words.string
        foldButton.accessibilityValue = t.opened ? "Expanded" : "Collapsed"
        let pillH = min(row.height, ceil(max(font.lineHeight, iconSide)) + 8)
        placeBacking(CGRect(x: row.minX - padX, y: row.minY + ((row.height - pillH) / 2).rounded(),
                            width: contentW + 2 * padX, height: pillH), radius: pillH / 2)
        PointerEffects.outlineDidLayout(foldButton)
    }

    @objc private func foldTapped() {
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
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

// MARK: - A bot's offer ([task-lists], board 4)

/// A bot offers a list, or a batch of tasks, as one card under its reply: what it would make, the tasks, and the
/// buttons ("Make Work & Add 9", "Add, No List", "Not Now"). Nothing is on your list until you tap. Answered, the card
/// says what happened in one line, with Undo (the list and its tasks go again). Tasks already on your page are moved
/// only when you say so ("Move 3 to Work" / "Leave Them"). What became of an offer answered elsewhere (the Tasks
/// page, another device) is read from `TodoOfferStates`.
final class TasksOfferCell: ChatBaseCell {
    static let reuse = "activity.tasksOffer"

    private final class LineView {
        let circle = UIImageView()
        let title = UILabel()
        let due = UILabel()
        init(in parent: UIView) {
            circle.contentMode = .scaleAspectFit
            title.lineBreakMode = .byTruncatingTail
            due.textColor = ChatPalette.label2
            for v: UIView in [circle, title, due] { v.isUserInteractionEnabled = false; parent.addSubview(v) }
        }
        var hidden = false { didSet { for v: UIView in [circle, title, due] { v.isHidden = hidden } } }
    }

    private let card = UIView()
    private let badge = UIImageView()
    private let header = UILabel()
    private let why = UILabel()
    private let more = UILabel()
    private let mainButton = UIButton(type: .system)
    private let status = UILabel()
    private let statusMark = UIImageView()
    private let footRule = UIView()
    private let leftButton = UIButton(type: .system)
    private let rightButton = UIButton(type: .system)
    private var lineViews: [LineView] = []
    private var layout: TasksOfferLayout?
    private var foot = TodoOfferFoot()
    private var leftTap: (() -> Void)?
    private var rightTap: (() -> Void)?
    private var busy = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        contentView.addSubview(card)
        badge.contentMode = .scaleAspectFit
        header.numberOfLines = 2
        why.numberOfLines = 3
        why.textColor = ChatPalette.label2
        more.textColor = ChatPalette.label2
        statusMark.contentMode = .scaleAspectFit
        status.lineBreakMode = .byTruncatingTail
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.8
        footRule.backgroundColor = ChatPalette.separator
        for v: UIView in [badge, header, why, more, statusMark, status, footRule] { v.isUserInteractionEnabled = false; contentView.addSubview(v) }
        mainButton.addTarget(self, action: #selector(mainTapped), for: .touchUpInside)
        mainButton.accessibilityIdentifier = "chat.offer.main"
        leftButton.contentHorizontalAlignment = .leading
        leftButton.addTarget(self, action: #selector(leftTapped), for: .touchUpInside)
        leftButton.accessibilityIdentifier = "chat.offer.left"
        rightButton.contentHorizontalAlignment = .trailing
        rightButton.addTarget(self, action: #selector(rightTapped), for: .touchUpInside)
        rightButton.accessibilityIdentifier = "chat.offer.right"
        for v in [mainButton, leftButton, rightButton] { contentView.addSubview(v) }
        accessibilityIdentifier = "chat.tasks-offer"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TasksOfferCell, _) in
            view.styleChatCard(view.card)
            view.paint()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(statesChanged), name: TodoOfferStates.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let green = TodoInk.ready

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.tasksOffer(let t)) = layout.content else { return }
        if self.layout?.offer.id != t.offer.id { busy = false }
        self.layout = t
        card.frame = t.cardFrame
        styleChatCard(card)
        badge.frame = t.badgeFrame
        header.font = HQFont.face(ofSize: t.font.pointSize, weight: .semibold)
        header.textColor = ChatPalette.label
        header.text = t.title
        header.frame = t.titleFrame
        header.accessibilityTraits = .header
        if let frame = t.whyFrame {
            why.isHidden = false
            why.font = t.detailFont
            why.text = t.offer.why.trimmingCharacters(in: .whitespacesAndNewlines)
            why.frame = frame
        } else {
            why.isHidden = true
        }
        while lineViews.count < t.lines.count { lineViews.append(LineView(in: contentView)) }
        for (i, v) in lineViews.enumerated() {
            guard i < t.lines.count else { v.hidden = true; continue }
            let line = t.lines[i]
            v.hidden = false
            v.circle.frame = line.circleFrame
            v.title.font = t.font
            v.title.frame = line.titleFrame
            v.due.font = t.detailFont
            v.due.text = line.due
            v.due.frame = line.dueFrame
        }
        if let frame = t.moreFrame {
            more.isHidden = false
            more.font = t.detailFont
            more.text = "+\(t.more) more"
            more.frame = frame
        } else {
            more.isHidden = true
        }
        let hairline = HQShape.pixel(traitCollection.displayScale)
        mainButton.frame = t.mainFrame
        let mark = ceil(t.font.pointSize * 1.1)
        statusMark.frame = CGRect(x: t.mainFrame.minX, y: t.mainFrame.midY - mark / 2, width: mark, height: mark)
        footRule.frame = CGRect(x: t.footFrame.minX + 14, y: t.footFrame.minY + 6, width: max(0, t.footFrame.width - 28), height: hairline)
        let half = t.footFrame.width / 2
        let footY = t.footFrame.minY + 6, footH = t.footFrame.height - 6
        leftButton.frame = CGRect(x: t.footFrame.minX + 14, y: footY, width: half - 14, height: footH)
        rightButton.frame = CGRect(x: t.footFrame.minX + half, y: footY, width: half - 14, height: footH)
        paint()
    }

    /// The card as the offer stands now: its tasks ticked once they are on your list, and the foot for its state.
    private func paint() {
        guard let t = layout else { return }
        let (offer, past) = TodoOfferStates.shown(t.offer)
        foot = TodoLists.chatFoot(offer, past: past)
        let added = offer.state == "accepted" && !t.offer.tasks.isEmpty
        let gone = offer.state == "undone" || offer.state == "declined"
        badge.image = UIImage(systemName: added ? "checkmark.square.fill" : "tray.and.arrow.down.fill")
        badge.tintColor = added ? Self.green : gone || past ? ChatPalette.label2 : ChatPalette.tintText
        for (i, v) in lineViews.enumerated() where i < t.lines.count {
            let line = t.lines[i]
            v.circle.image = UIImage(systemName: added ? "checkmark.circle.fill" : "circle",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: line.circleFrame.height, weight: .light))
            v.circle.tintColor = added ? Self.green : ChatPalette.label3
            v.title.attributedText = NSAttributedString(string: line.title, attributes: gone
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2, .font: t.font]
                : [.foregroundColor: ChatPalette.label, .font: t.font])
        }
        if let main = foot.main {
            var config = UIButton.Configuration.filled()
            if Theme.isDesktop || DeviceWord.isMac {   // the look's squared buttons, as on the Tasks page's card
                config.cornerStyle = .fixed
                config.background.cornerRadius = DeviceWord.isMac ? MacPush.radius : DesktopRows.radius
            } else {
                config.cornerStyle = .capsule
            }
            config.baseBackgroundColor = ChatPalette.tint
            config.baseForegroundColor = ChatPalette.onTint
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            config.titleLineBreakMode = .byTruncatingTail
            config.attributedTitle = AttributedString(main.title, attributes: AttributeContainer([
                .font: HQFont.face(ofSize: t.font.pointSize, weight: .semibold)]))
            config.showsActivityIndicator = busy
            mainButton.configuration = config
            mainButton.isHidden = false
            mainButton.isEnabled = !busy
            mainButton.accessibilityLabel = main.title
            status.isHidden = true
            statusMark.isHidden = true
        } else {
            mainButton.isHidden = true
            status.isHidden = false
            statusMark.isHidden = !foot.good
            statusMark.image = UIImage(systemName: "checkmark.circle.fill")
            statusMark.tintColor = Self.green
            status.font = HQFont.face(ofSize: t.font.pointSize, weight: foot.good ? .semibold : .regular)
            status.textColor = foot.good ? Self.green : ChatPalette.label2
            status.text = foot.line
            let x = foot.good ? statusMark.frame.maxX + 7 : t.mainFrame.minX
            status.frame = CGRect(x: x, y: t.mainFrame.minY, width: t.mainFrame.maxX - x, height: t.mainFrame.height)
        }
        // The quiet row: at its start Open Tasks, or the first other answer; at its end Undo, or the second.
        var left: (String, () -> Void)?
        var right: (String, () -> Void)?
        if foot.opensTasks {
            left = ("Open Tasks", { [weak self] in
                Haptics.play(.selection)
                (self?.delegate as? ActivityCellDelegate)?.activityCellOpenTask(id: nil)
            })
        } else if let first = foot.others.first {
            left = (first.title, { [weak self] in self?.answer(first.action, list: first.makesList) })
        }
        if foot.undo {
            right = ("Undo", { [weak self] in self?.answer(.undo, list: true) })
        } else if foot.others.count > 1 {
            let second = foot.others[1]
            right = (second.title, { [weak self] in self?.answer(second.action, list: second.makesList) })
        }
        // One quiet answer alone ("Not Now") sits at the row's end, under the filled button's end.
        if !foot.opensTasks, right == nil, foot.others.count == 1, let only = left { right = only; left = nil }
        set(leftButton, left?.0, font: t.font)
        set(rightButton, right?.0, font: t.font)
        leftTap = left?.1
        rightTap = right?.1
        leftButton.isEnabled = !busy
        rightButton.isEnabled = !busy
    }

    private func set(_ button: UIButton, _ title: String?, font: UIFont) {
        button.isHidden = title == nil
        guard let title else { return }
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText]), for: .normal)
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText.withAlphaComponent(0.5)]), for: .highlighted)
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.label3]), for: .disabled)
        button.accessibilityLabel = title
    }

    private func answer(_ action: TodoOfferAction, list: Bool) {
        guard !busy, let id = layout?.offer.id else { return }
        Haptics.play(.light)   // at the tap; success (or error) follows once the gateway answers
        busy = true
        paint()
        (delegate as? ActivityCellDelegate)?.activityCellAnswerOffer(id: id, action: action, list: list) { [weak self] ok in
            Haptics.play(ok ? .success : .error)
            guard let self, self.layout?.offer.id == id else { return }
            self.busy = false
            self.paint()
        }
    }

    @objc private func mainTapped() {
        guard let main = foot.main else { return }
        answer(main.action, list: main.makesList)
    }

    @objc private func leftTapped() { leftTap?() }
    @objc private func rightTapped() { rightTap?() }
    @objc private func statesChanged() { if !busy { paint() } }
}

// MARK: - A bot's offer to close a task ([chat-mark-done])

/// A bot thinks a task of yours is done and says why, under its reply: the task page's line, the task's title, and the
/// page's two buttons, Mark Done and Keep Open. Answered (here, on the page, on another device), the buttons give way to
/// one quiet line: "Marked Done" with Undo, "Kept Open", "No longer on your list". The bot that marked a task done
/// because you said so draws the same card already answered, with Undo. The card (outside its buttons) opens the task.
/// What it shows is the row's state, read from the Tasks store each time the chat's rows are built.
final class TaskCloseCell: ChatBaseCell {
    static let reuse = "activity.taskClose"

    /// The card's body, behind the buttons: the line, the circle and the title. A tap on it opens the task.
    private final class BodyView: UIControl {
        let mark = UIImageView()
        let line = UILabel()
        let circle = UIImageView()
        let title = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            mark.contentMode = .scaleAspectFit
            line.numberOfLines = 4
            line.lineBreakMode = .byTruncatingTail
            circle.contentMode = .scaleAspectFit
            title.numberOfLines = 3
            title.lineBreakMode = .byTruncatingTail
            for v: UIView in [mark, line, circle, title] { v.isUserInteractionEnabled = false; addSubview(v) }
            PointerEffects.surface(self)   // [mac] lit under the pointer, deeper while pressed, as a task row in the Added card
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityHint = "Opens the task"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.5) } }   // motion-ok: colour only
    }

    private let card = UIView()
    private let body = BodyView()
    private let doneButton = UIButton(type: .system)
    private let keepButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let statusMark = UIImageView()
    private let status = UILabel()
    private var layout: TaskCloseLayout?
    /// A tap is on its way to the gateway: the buttons wait (the card shows what the store says once it answers).
    private var busy: TodoCloseCards.Action?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        contentView.addSubview(card)
        body.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        contentView.addSubview(body)
        statusMark.contentMode = .scaleAspectFit
        status.numberOfLines = 3
        status.lineBreakMode = .byTruncatingTail
        for v: UIView in [statusMark, status] { v.isUserInteractionEnabled = false; contentView.addSubview(v) }
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        keepButton.addTarget(self, action: #selector(keepTapped), for: .touchUpInside)
        undoButton.contentHorizontalAlignment = .trailing
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        for v in [doneButton, keepButton, undoButton] { contentView.addSubview(v) }
        accessibilityIdentifier = "chat.task-close"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TaskCloseCell, _) in
            view.styleChatCard(view.card)
            view.paint()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.taskClose(let t)) = layout.content else { return }
        if self.layout?.row.taskId != t.row.taskId || self.layout?.row.state != t.row.state { busy = nil }
        self.layout = t
        card.frame = t.cardFrame
        styleChatCard(card)
        body.frame = t.cardFrame
        PointerEffects.fit(body, card: t.cardFrame, radius: ChatMetrics.insetCardRadius)
        let origin = t.cardFrame.origin
        if let lineFrame = t.lineFrame, let markFrame = t.markFrame, let line = t.row.line {
            body.mark.isHidden = false
            body.line.isHidden = false
            body.mark.frame = markFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            body.mark.image = UIImage(systemName: "checkmark.circle",
                                      withConfiguration: UIImage.SymbolConfiguration(font: HQFont.face(ofSize: t.detailFont.pointSize, weight: .semibold)))
            body.line.font = t.detailFont
            body.line.text = line
            body.line.frame = lineFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        } else {
            body.mark.isHidden = true
            body.line.isHidden = true
        }
        body.circle.frame = t.circleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        body.title.frame = t.titleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        doneButton.frame = t.doneFrame
        keepButton.frame = t.keepFrame
        undoButton.frame = t.undoFrame
        let mark = ceil(t.font.pointSize * 1.1)
        statusMark.frame = CGRect(x: t.statusFrame.minX, y: t.statusFrame.midY - mark / 2, width: mark, height: mark)
        let id = t.row.taskId
        body.accessibilityIdentifier = "chat.task-close.\(id)"
        doneButton.accessibilityIdentifier = "chat.task-close.\(id).done"
        keepButton.accessibilityIdentifier = "chat.task-close.\(id).keep"
        undoButton.accessibilityIdentifier = "chat.task-close.\(id).undo"
        status.accessibilityIdentifier = "chat.task-close.\(id).status"
        paint()
    }

    /// The card for its state: the buttons while the offer waits, else the quiet line (and Undo on a done task).
    private func paint() {
        guard let t = layout else { return }
        let row = t.row
        let done: Bool
        if case .done = row.state { done = true } else { done = false }
        body.mark.tintColor = TodoInk.ready   // the task page's mark for a bot's "looks done"
        body.line.textColor = ChatPalette.label
        body.circle.image = UIImage(systemName: done ? "checkmark.circle.fill" : "circle",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: t.circleFrame.height, weight: .light))
        body.circle.tintColor = done ? TodoInk.ready : ChatPalette.label3
        body.title.attributedText = NSAttributedString(string: row.title, attributes: done || row.state == .gone
            ? [.font: t.font, .foregroundColor: ChatPalette.label2, .strikethroughStyle: NSUnderlineStyle.single.rawValue]
            : [.font: t.font, .foregroundColor: ChatPalette.label])
        let words = TodoCloseCards.words(row.state)
        body.accessibilityLabel = [row.line, row.title, words].compactMap { $0 }.joined(separator: ", ")
        body.isEnabled = row.state != .gone

        let waiting = row.state == .waiting
        show(doneButton, waiting)
        show(keepButton, waiting)
        if waiting {
            style(doneButton, "Mark Done", main: true, font: t.font, spinning: busy == .markDone)
            style(keepButton, "Keep Open", main: false, font: t.font, spinning: busy == .keepOpen)
            doneButton.isEnabled = !row.readOnly && busy == nil
            keepButton.isEnabled = !row.readOnly && busy == nil
        }
        status.isHidden = waiting
        statusMark.isHidden = !done
        statusMark.image = UIImage(systemName: "checkmark.circle.fill")
        statusMark.tintColor = TodoInk.ready
        if let words {
            let x = done ? statusMark.frame.maxX + 7 : t.statusFrame.minX
            status.frame = CGRect(x: x, y: t.statusFrame.minY, width: t.statusFrame.maxX - x, height: t.statusFrame.height)
            status.font = HQFont.face(ofSize: t.font.pointSize, weight: done ? .semibold : .regular)
            status.textColor = done ? TodoInk.ready : ChatPalette.label2
            status.text = words
            status.accessibilityLabel = words
        }
        var showsUndo = false
        if case .done(let undo) = row.state { showsUndo = undo }
        show(undoButton, showsUndo)
        if showsUndo {
            let font = t.font
            undoButton.setAttributedTitle(NSAttributedString(string: "Undo", attributes: [.font: font, .foregroundColor: ChatPalette.tintText]), for: .normal)
            undoButton.setAttributedTitle(NSAttributedString(string: "Undo", attributes: [.font: font, .foregroundColor: ChatPalette.tintText.withAlphaComponent(0.5)]), for: .highlighted)
            undoButton.setAttributedTitle(NSAttributedString(string: "Undo", attributes: [.font: font, .foregroundColor: ChatPalette.label3]), for: .disabled)
            undoButton.accessibilityLabel = "Undo"
            undoButton.accessibilityHint = "Puts the task back on your list"
            undoButton.isEnabled = busy == nil
        }
    }

    /// A button that isn't shown is out of the cell altogether, not only hidden: a hidden one that had been drawn stayed
    /// in the accessibility tree (a dimmed "Mark Done" beside "Marked Done").
    private func show(_ button: UIButton, _ shown: Bool) {
        button.isHidden = !shown
        if shown, button.superview == nil { contentView.addSubview(button) }
        if !shown, button.superview != nil { button.removeFromSuperview() }
    }

    /// The task page's two buttons: the filled one, and the quiet one beside it (the look's squared corners on the
    /// desktop look and the Mac, as the offer card's).
    private func style(_ button: UIButton, _ title: String, main: Bool, font: UIFont, spinning: Bool) {
        var config = main ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        if Theme.isDesktop || DeviceWord.isMac {
            config.cornerStyle = .fixed
            config.background.cornerRadius = DeviceWord.isMac ? MacPush.radius : DesktopRows.radius
        } else {
            config.cornerStyle = .capsule
        }
        config.baseBackgroundColor = main ? ChatPalette.tint : ChatPalette.fill3
        config.baseForegroundColor = main ? ChatPalette.onTint : ChatPalette.tintText
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        config.titleLineBreakMode = .byTruncatingTail
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: HQFont.face(ofSize: font.pointSize, weight: .semibold)]))
        config.showsActivityIndicator = spinning
        button.configuration = config
        button.accessibilityLabel = title
    }

    private func send(_ action: TodoCloseCards.Action) {
        guard busy == nil, let id = layout?.row.taskId else { return }
        PagesHaptics.selection()   // as the task page's Mark Done, Keep Open and Reopen
        busy = action
        paint()
        (delegate as? ActivityCellDelegate)?.activityCellCloseTask(id: id, action: action) { [weak self] ok in
            if action == .markDone, ok { PagesHaptics.success() }
            if !ok { PagesHaptics.error() }
            guard let self, self.layout?.row.taskId == id else { return }
            self.busy = nil
            self.paint()
        }
    }

    @objc private func doneTapped() { send(.markDone) }
    @objc private func keepTapped() { send(.keepOpen) }
    @objc private func undoTapped() { send(.reopen) }

    @objc private func openTapped() {
        guard let id = layout?.row.taskId, layout?.row.state != .gone else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellOpenTask(id: id)
    }

    /// The table set this cell aside (its row was drawn again in another cell): its buttons go with it. Left showing,
    /// a set-aside cell's dimmed "Mark Done" stayed in the accessibility tree beside the new cell's "Marked Done".
    override var isHidden: Bool {
        didSet {
            guard isHidden else { return }
            busy = nil
            for button in [doneButton, keepButton, undoButton] { show(button, false) }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        busy = nil
    }
}
