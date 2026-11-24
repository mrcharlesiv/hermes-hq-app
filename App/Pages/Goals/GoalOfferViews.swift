// [goals step 3] A bot's card for a goal (docs/goals.md "Step 3" and "Step 4"; boards 3, 4 and 5): a new goal, a plan,
// the weekly check-in, or tasks for a goal. Nothing changes until you tap. In a chat it is a cell under the bot's reply
// (`GoalOfferCell`, the same height in every state, so the chat never jumps); on Today and on the goal's page it is
// `GoalOfferCard`. Both draw their words from `GoalOffers` and answer through the Tasks store.

import SwiftUI
import UIKit

// MARK: - In a chat

final class GoalOfferCell: ChatBaseCell {
    static let reuse = "activity.goalOffer"

    private final class LineView {
        let mark = UIImageView()
        let title = UILabel()
        let trail = UILabel()
        let face = UIImageView()
        init(in parent: UIView) {
            mark.contentMode = .scaleAspectFit
            title.lineBreakMode = .byTruncatingTail
            trail.textColor = ChatPalette.label2
            trail.textAlignment = .right
            trail.lineBreakMode = .byTruncatingTail
            face.contentMode = .scaleAspectFill
            face.clipsToBounds = true
            for v: UIView in [mark, title, trail, face] { v.isUserInteractionEnabled = false; parent.addSubview(v) }
        }
        var hidden = false { didSet { for v: UIView in [mark, title, trail, face] { v.isHidden = hidden } } }
    }

    private let card = UIView()
    private let kickerFace = UIImageView()
    private let kicker = UILabel()
    private let mark = UIImageView()
    private let header = UILabel()
    private let summary = UILabel()
    private var headerLabels: [UILabel] = []
    /// [goals set-up] The plan's "Built on" lines, and its set-up rows (a label and a value each).
    private var noteLabels: [UILabel] = []
    private var setupLabels: [(label: UILabel, value: UILabel)] = []
    private var moreButtons: [UIButton] = []
    private var lineViews: [LineView] = []
    private var buttons: [UIButton] = []
    private let status = UILabel()
    private let statusMark = UIImageView()
    private let undoButton = UIButton(type: .system)
    private let quietButton = UIButton(type: .system)
    private let quietNote = UILabel()
    private var layout: GoalOfferLayout?
    private var foot = GoalOfferFoot()
    private var busy = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        contentView.addSubview(card)
        kickerFace.contentMode = .scaleAspectFill
        kickerFace.clipsToBounds = true
        kicker.lineBreakMode = .byTruncatingTail
        mark.contentMode = .scaleAspectFit
        header.numberOfLines = 2
        summary.numberOfLines = 4
        statusMark.contentMode = .scaleAspectFit
        status.lineBreakMode = .byTruncatingTail
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.8
        quietNote.numberOfLines = 3
        quietNote.textAlignment = .center
        quietNote.textColor = ChatPalette.label2
        for v: UIView in [kickerFace, kicker, mark, header, summary, statusMark, status, quietNote] {
            v.isUserInteractionEnabled = false
            contentView.addSubview(v)
        }
        undoButton.contentHorizontalAlignment = .trailing
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        undoButton.accessibilityIdentifier = "chat.goal-offer.undo"
        quietButton.addTarget(self, action: #selector(quietTapped), for: .touchUpInside)
        quietButton.accessibilityIdentifier = "chat.goal-offer.quiet"
        for v in [undoButton, quietButton] { contentView.addSubview(v) }
        accessibilityIdentifier = "chat.goal-offer"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: GoalOfferCell, _) in
            view.styleChatCard(view.card)
            view.drawFaces()
            view.paint()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(statesChanged), name: TodoOfferStates.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let green = TodoInk.ready

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .activity(.goalOffer(let g)) = layout.content else { return }
        if self.layout?.row.offer.id != g.row.offer.id { busy = false }
        self.layout = g
        let r = g.row
        card.frame = g.cardFrame
        styleChatCard(card)
        if let frame = g.kickerFrame, let words = r.kicker {
            kicker.isHidden = false
            let side = ceil(g.detailFont.lineHeight * 0.9)
            kickerFace.isHidden = r.kickerBot == nil
            kickerFace.frame = CGRect(x: frame.minX, y: frame.midY - side / 2, width: side, height: side)
            kickerFace.layer.cornerRadius = side * 0.28
            let x = r.kickerBot == nil ? frame.minX : kickerFace.frame.maxX + 6
            kicker.frame = CGRect(x: x, y: frame.minY, width: frame.maxX - x, height: frame.height)
            let parts = words.components(separatedBy: " · ")
            let text = NSMutableAttributedString(string: parts.first ?? words, attributes: [
                .font: HQFont.face(ofSize: g.detailFont.pointSize, weight: .semibold), .foregroundColor: ChatPalette.tintText])
            if parts.count > 1 {
                text.append(NSAttributedString(string: " · " + parts.dropFirst().joined(separator: " · "),
                                               attributes: [.font: g.detailFont, .foregroundColor: ChatPalette.label2]))
            }
            kicker.attributedText = text
        } else {
            kicker.isHidden = true
            kickerFace.isHidden = true
        }
        mark.frame = g.markFrame
        mark.image = UIImage(systemName: "smallcircle.filled.circle")
        mark.tintColor = UIColor(r.color.ink)
        let headFont = HQFont.face(ofSize: g.font.pointSize, weight: .semibold)
        let head = NSMutableAttributedString(string: r.title, attributes: [.font: headFont, .foregroundColor: ChatPalette.label])
        if !r.tag.isEmpty {
            head.append(NSAttributedString(string: "  " + r.tag, attributes: [.font: g.detailFont, .foregroundColor: ChatPalette.label2]))
        }
        header.attributedText = head
        header.frame = g.titleFrame
        header.accessibilityLabel = r.spoken
        header.accessibilityTraits = .header
        if let frame = g.summaryFrame, let words = r.summary {
            summary.isHidden = false
            summary.font = g.detailFont
            summary.textColor = ChatPalette.label
            summary.text = words
            summary.frame = frame
        } else {
            summary.isHidden = true
        }
        while headerLabels.count < g.headers.count {
            let label = UILabel()
            label.isUserInteractionEnabled = false
            contentView.addSubview(label)
            headerLabels.append(label)
        }
        for (i, label) in headerLabels.enumerated() {
            guard i < g.headers.count else { label.isHidden = true; continue }
            label.isHidden = false
            label.frame = g.headers[i].frame
            label.attributedText = NSAttributedString(string: g.headers[i].text, attributes: [
                .font: g.smallFont, .foregroundColor: ChatPalette.label2, .kern: 0.4])
            label.accessibilityTraits = .header
        }
        while noteLabels.count < g.notes.count {
            let label = UILabel()
            label.numberOfLines = 2
            label.isUserInteractionEnabled = false
            label.accessibilityIdentifier = "chat.goal-offer.built-on"
            contentView.addSubview(label)
            noteLabels.append(label)
        }
        for (i, label) in noteLabels.enumerated() {
            guard i < g.notes.count else { label.isHidden = true; continue }
            label.isHidden = false
            label.frame = g.notes[i].frame
            label.font = g.detailFont
            label.textColor = ChatPalette.label2
            label.text = g.notes[i].text
        }
        while setupLabels.count < g.setupLines.count {
            let label = UILabel(), value = UILabel()
            value.numberOfLines = 2
            for v in [label, value] { v.isUserInteractionEnabled = false; contentView.addSubview(v) }
            setupLabels.append((label, value))
        }
        for (i, pair) in setupLabels.enumerated() {
            guard i < g.setupLines.count else { pair.label.isHidden = true; pair.value.isHidden = true; continue }
            let line = g.setupLines[i]
            pair.label.isHidden = false
            pair.value.isHidden = false
            pair.label.frame = line.labelFrame
            pair.value.frame = line.valueFrame
            pair.label.font = g.detailFont
            pair.label.textColor = ChatPalette.label2
            pair.label.text = line.row.label
            // One element per row for VoiceOver ("Name: Draw every day"), read in the card's order.
            pair.label.isAccessibilityElement = false
            pair.value.accessibilityLabel = GoalOffers.setupSpoken(line.row)
            pair.value.accessibilityIdentifier = "chat.goal-offer.setup.\(line.row.key)"
        }
        while lineViews.count < g.lines.count { lineViews.append(LineView(in: contentView)) }
        for (i, v) in lineViews.enumerated() {
            guard i < g.lines.count else { v.hidden = true; continue }
            let line = g.lines[i]
            v.hidden = false
            v.mark.frame = line.markFrame
            v.title.font = g.detailFont
            v.title.frame = line.titleFrame
            v.trail.font = HQFont.face(ofSize: (g.detailFont.pointSize * 0.9).rounded())
            let side = ceil(line.trailFrame.height * 0.82)
            let trailText: String
            if let bot = line.line.bot {
                trailText = line.line.botName ?? bot
                v.face.isHidden = false
                let width = ceil((trailText as NSString).size(withAttributes: [.font: v.trail.font as Any]).width)
                let textW = min(width, line.trailFrame.width - side - 5)
                v.trail.frame = CGRect(x: line.trailFrame.maxX - textW, y: line.trailFrame.minY, width: textW, height: line.trailFrame.height)
                v.face.frame = CGRect(x: v.trail.frame.minX - 5 - side, y: line.trailFrame.midY - side / 2, width: side, height: side)
                v.face.layer.cornerRadius = side * 0.28
            } else {
                trailText = line.line.milestone ? line.line.due : (line.line.due.isEmpty ? "You" : "You · \(line.line.due)")
                v.face.isHidden = true
                v.trail.frame = line.trailFrame
            }
            v.trail.text = trailText
        }
        while moreButtons.count < g.mores.count {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
            button.accessibilityIdentifier = "chat.goal-offer.more"
            contentView.addSubview(button)
            moreButtons.append(button)
        }
        for (i, button) in moreButtons.enumerated() {
            guard i < g.mores.count else { button.isHidden = true; continue }
            button.isHidden = false
            button.frame = g.mores[i].frame
            button.setAttributedTitle(NSAttributedString(string: g.mores[i].text, attributes: [
                .font: g.detailFont, .foregroundColor: ChatPalette.label2]), for: .normal)
            button.accessibilityLabel = g.mores[i].text.replacingOccurrences(of: " ›", with: "")
            button.accessibilityHint = "Shows the whole card"
        }
        let mark = ceil(g.font.pointSize * 1.1)
        statusMark.frame = CGRect(x: g.buttonsFrame.minX, y: g.buttonsFrame.midY - mark / 2, width: mark, height: mark)
        undoButton.frame = CGRect(x: g.buttonsFrame.maxX - 90, y: g.buttonsFrame.minY, width: 90, height: g.buttonsFrame.height)
        if let frame = g.quietFrame {
            quietButton.frame = frame
            quietNote.frame = frame
        }
        drawFaces()
        paint()
    }

    private func drawFaces() {
        guard let g = layout else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let scale = traitCollection.displayScale
        if let bot = g.row.kickerBot {
            kickerFace.image = BotFaces.shared.faceImage(profile: bot, raw: g.row.kickerHead, side: max(1, kickerFace.bounds.width),
                                                         scale: scale, dark: dark, shape: .appIcon)
        }
        for (i, v) in lineViews.enumerated() where i < g.lines.count {
            guard let bot = g.lines[i].line.bot else { continue }
            v.face.image = BotFaces.shared.faceImage(profile: bot, raw: g.lines[i].line.head, side: max(1, v.face.bounds.width),
                                                     scale: scale, dark: dark, shape: .appIcon)
        }
    }

    /// The card as the offer stands now: ticked once its tasks are on your list, and the foot for its state.
    private func paint() {
        guard let g = layout else { return }
        let live = TodoOfferStates.live(g.row.offer.id)
        let offer = live.offer ?? g.row.offer
        foot = GoalOffers.foot(offer, past: live.past)
        let added = offer.state == "accepted"
        let gone = offer.state == "undone" || offer.state == "declined"
        // [goals set-up] The set-up rows follow the state in ink alone (struck through once undone or declined).
        for (i, pair) in setupLabels.enumerated() where i < g.setupLines.count {
            pair.value.attributedText = NSAttributedString(string: g.setupLines[i].row.value, attributes: gone
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2, .font: g.detailFont]
                : [.foregroundColor: ChatPalette.label, .font: g.detailFont])
        }
        for (i, v) in lineViews.enumerated() where i < g.lines.count {
            let line = g.lines[i]
            // [goals set-up] A plus once taken: the line was added, not done.
            let symbol = GoalOffers.lineMark(milestone: line.line.milestone, added: added)
            v.mark.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: line.markFrame.height, weight: .light))
            v.mark.tintColor = added ? Self.green : ChatPalette.label3
            v.title.accessibilityValue = GoalOffers.lineState(added: added)
            v.title.attributedText = NSAttributedString(string: line.line.title, attributes: gone
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: ChatPalette.label2, .font: g.detailFont]
                : [.foregroundColor: ChatPalette.label, .font: g.detailFont])
        }
        // The buttons: one row, the filled one first, the others outlined; the same row holds the answered line.
        let shown: [GoalOfferButton] = foot.main.map { [$0] + foot.others } ?? []
        while buttons.count < shown.count {
            let button = UIButton(type: .system)
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            contentView.addSubview(button)
            buttons.append(button)
        }
        let gap: CGFloat = 8
        let count = CGFloat(max(1, shown.count))
        // Equal widths while every title fits; a narrow pane (the Mac's chat beside a goal) gives each what it needs.
        let natural = shown.map { item in
            ceil((item.title as NSString).size(withAttributes: [.font: Self.titleFont(g.font, main: item.main)]).width) + Self.titleInset * 2 + 2
        }
        let row = GoalOffers.buttonWidths(natural: natural, available: g.buttonsFrame.width - gap * (count - 1))
        var x = g.buttonsFrame.minX
        for (i, button) in buttons.enumerated() {
            guard i < shown.count else { button.isHidden = true; continue }
            let item = shown[i]
            button.isHidden = false
            button.tag = i
            let width = i == shown.count - 1 ? g.buttonsFrame.maxX - x : row.widths[i]
            button.frame = CGRect(x: x, y: g.buttonsFrame.minY, width: width, height: g.buttonsFrame.height)
            x += width + gap
            button.configuration = Self.configuration(item.title, main: item.main, font: g.font, busy: busy && item.main, scale: row.scale)
            button.isEnabled = !busy
            button.accessibilityLabel = item.title
            button.accessibilityIdentifier = "chat.goal-offer.\(item.title)"
        }
        if foot.main == nil {
            status.isHidden = false
            statusMark.isHidden = !foot.good
            statusMark.image = UIImage(systemName: "checkmark.circle.fill")
            statusMark.tintColor = Self.green
            status.font = HQFont.face(ofSize: g.font.pointSize, weight: foot.good ? .semibold : .regular)
            status.textColor = foot.good ? Self.green : ChatPalette.label2
            status.text = foot.line
            let x = foot.good ? statusMark.frame.maxX + 7 : g.buttonsFrame.minX
            status.frame = CGRect(x: x, y: g.buttonsFrame.minY, width: g.buttonsFrame.maxX - x - (foot.undo ? 96 : 0), height: g.buttonsFrame.height)
            undoButton.isHidden = !foot.undo
            set(undoButton, "Undo", font: g.font)
            undoButton.isEnabled = !busy
        } else {
            status.isHidden = true
            statusMark.isHidden = true
            undoButton.isHidden = true
        }
        // The quiet line keeps its room in every state: the button while it waits, then nothing; a note stays.
        if let words = g.row.quiet, g.quietFrame != nil {
            if g.row.quietIsButton {
                quietNote.isHidden = true
                quietButton.isHidden = foot.quiet == nil
                quietButton.setAttributedTitle(NSAttributedString(string: words, attributes: [
                    .font: g.detailFont, .foregroundColor: ChatPalette.label2]), for: .normal)
                quietButton.setAttributedTitle(NSAttributedString(string: words, attributes: [
                    .font: g.detailFont, .foregroundColor: ChatPalette.label3]), for: .highlighted)
                quietButton.accessibilityLabel = words
                quietButton.isEnabled = !busy
            } else {
                quietButton.isHidden = true
                quietNote.isHidden = false
                quietNote.font = HQFont.face(ofSize: (g.detailFont.pointSize * 0.93).rounded())
                quietNote.text = words
            }
        } else {
            quietButton.isHidden = true
            quietNote.isHidden = true
        }
    }

    static let titleInset: CGFloat = 6

    static func titleFont(_ font: UIFont, main: Bool, scale: CGFloat = 1) -> UIFont {
        HQFont.face(ofSize: font.pointSize * 0.94 * scale, weight: main ? .semibold : .medium)
    }

    static func configuration(_ title: String, main: Bool, font: UIFont, busy: Bool, scale: CGFloat = 1) -> UIButton.Configuration {
        var config = main ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        let square = Theme.isDesktop || DeviceWord.isMac
        if square {
            config.cornerStyle = .fixed
            config.background.cornerRadius = DeviceWord.isMac ? MacPush.radius : DesktopRows.radius
        } else {
            config.cornerStyle = .capsule
        }
        if main {
            config.baseBackgroundColor = ChatPalette.tint
            config.baseForegroundColor = ChatPalette.onTint
        } else {
            config.baseForegroundColor = ChatPalette.tintText
            config.background.backgroundColor = .clear
            config.background.strokeColor = ChatPalette.separator
            config.background.strokeWidth = 1
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: titleInset, bottom: 0, trailing: titleInset)
        config.titleLineBreakMode = .byTruncatingTail
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: titleFont(font, main: main, scale: scale)]))
        config.showsActivityIndicator = busy
        return config
    }

    private func set(_ button: UIButton, _ title: String, font: UIFont) {
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText]), for: .normal)
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.tintText.withAlphaComponent(0.5)]), for: .highlighted)
        button.setAttributedTitle(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ChatPalette.label3]), for: .disabled)
        button.accessibilityLabel = title
    }

    private func answer(_ button: GoalOfferButton) {
        guard !busy, let g = layout else { return }
        guard let action = button.action else {
            // Change It / Change: not an answer. The goal's chat takes the cursor.
            Haptics.play(.selection)
            (delegate as? ActivityCellDelegate)?.activityCellChangeGoalOffer(goal: g.row.offer.goal ?? g.row.offer.madeGoal)
            return
        }
        send(action, plan: button.plan, inGoal: button.inGoal)
    }

    private func send(_ action: TodoOfferAction, plan: Bool, inGoal: Bool) {
        guard !busy, let id = layout?.row.offer.id else { return }
        Haptics.play(.light)   // at the tap; success (or error) follows once the gateway answers
        busy = true
        paint()
        (delegate as? ActivityCellDelegate)?.activityCellAnswerGoalOffer(id: id, action: action, plan: plan, inGoal: inGoal) { [weak self] ok in
            Haptics.play(ok ? .success : .error)
            guard let self, self.layout?.row.offer.id == id else { return }
            self.busy = false
            self.paint()
        }
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        let shown: [GoalOfferButton] = foot.main.map { [$0] + foot.others } ?? []
        guard shown.indices.contains(sender.tag) else { return }
        answer(shown[sender.tag])
    }

    @objc private func undoTapped() { send(.undo, plan: true, inGoal: true) }
    @objc private func quietTapped() { if let quiet = foot.quiet { answer(quiet) } }
    @objc private func moreTapped() {
        guard let g = layout else { return }
        Haptics.play(.selection)
        (delegate as? ActivityCellDelegate)?.activityCellShowGoalOffer(id: g.row.offer.id)
    }
    @objc private func statesChanged() { if !busy { paint() } }

    override func prepareForReuse() {
        super.prepareForReuse()
        busy = false
    }
}

// MARK: - On Today and on the goal's page

/// What a goal's offer card draws on the Tasks page.
struct GoalOfferCardModel: Hashable {
    var offer: TodoOffer
    var goal: Goal?
    /// "Hermes · Monday check-in" (the check-in only).
    var kicker: String?
    var botName: String
    var head: JSONValue?
    var busy = false
    /// What the gateway said became of it (Undo while it shows).
    var foot: GoalOfferFoot
    var lead: String?
    /// A bot's name and face by its id.
    var names: [String: String] = [:]
    var heads: [String: JSONValue] = [:]
}

/// On Today (one at a time, under the list offers) and on the goal's page: the same card as in the chat.
struct GoalOfferCard: View {
    var model: GoalOfferCardModel
    var enabled: Bool
    var tap: (GoalOfferButton) -> Void
    var undo: () -> Void
    var more: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let offer = model.offer
        VStack(alignment: .leading, spacing: 8) {
            if let kicker = model.kicker {
                HStack(spacing: 6) {
                    HeadImage(raw: model.head, profile: offer.bot, size: 16).frame(width: 16, height: 16).accessibilityHidden(true)
                    let parts = kicker.components(separatedBy: " · ")
                    (Text(parts.first ?? kicker).foregroundStyle(Color.hqTintText).fontWeight(.semibold)
                     + Text(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "").foregroundStyle(Color.hqLabel2))
                        .font(Font.hq(.footnote))
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle((model.goal?.tint ?? .blue).ink)
                    .accessibilityHidden(true)
                (Text(offer.title.isEmpty ? (model.goal?.title ?? "A goal") : offer.title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                 + Text(offer.kind == "checkin" ? "" : "  " + GoalOffers.tag(offer)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(GoalOffers.spoken(offer, goal: model.goal, botName: name))
                    .accessibilityAddTraits(.isHeader)
            }
            let words = offer.kind == "checkin" ? offer.summary : (offer.kind == "goal" ? offer.why : "")
            if !words.isEmpty {
                Text(words)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let added = offer.state == "accepted"
            let gone = offer.state == "undone" || offer.state == "declined"
            // [goals set-up] What the plan rests on (quiet lines), then what accepting it also sets on the goal. Both are
            // the offer's own words, so they hold the card's height in every state; only their ink follows it.
            let builtOn = GoalOffers.builtOn(offer)
            if !builtOn.isEmpty {
                section(GoalOffers.builtOnHeader) {
                    ForEach(Array(builtOn.enumerated()), id: \.offset) { _, words in
                        Text(words)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("goal.offer-card.built-on")
                    }
                }
            }
            let setup = GoalOffers.setupRows(offer, now: Date())
            if !setup.isEmpty {
                section(GoalOffers.setupHeader) {
                    ForEach(setup, id: \.key) { row in setupLine(row, gone: gone) }
                }
            }
            if !offer.milestones.isEmpty {
                section(GoalOffers.milestoneCount(offer.milestones.count)) {
                    ForEach(Array(offer.milestones.prefix(GoalOffers.shown).enumerated()), id: \.offset) { _, m in
                        line(m.title, milestone: true, added: added, gone: gone) { trail(due: m.due, bot: nil, milestone: true) }
                    }
                    if offer.milestones.count > GoalOffers.shown { moreLine(offer.milestones.count - GoalOffers.shown) }
                }
            }
            if !offer.tasks.isEmpty {
                section(offer.kind == "tasks" ? nil : (offer.kind == "checkin" ? "This week" : "This week · \(TodoLists.count(offer.tasks.count))")) {
                    ForEach(Array(offer.tasks.prefix(GoalOffers.shown).enumerated()), id: \.offset) { _, task in
                        line(task.title, milestone: false, added: added, gone: gone) { trail(due: task.due, bot: task.botFor(offer), milestone: false) }
                    }
                    if offer.tasks.count > GoalOffers.shown { moreLine(offer.tasks.count - GoalOffers.shown) }
                }
            }
            footer
            if offer.kind == "tasks", let note = GoalOffers.leadNote(offer, goal: model.goal, botName: name) {
                Text(note)
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TaskCardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal.offer-card.\(offer.kind)")
    }

    private func name(_ id: String?) -> String {
        guard let id else { return model.botName }
        return model.names[id] ?? PagesNames.botName(id, bots: [])
    }

    @ViewBuilder private var footer: some View {
        let foot = model.foot
        if foot.main != nil {
            buttons(foot)
        } else {
            // [goals set-up] One height in every state (docs/goals.md "Offer cards"): the answered line stands in the
            // room the buttons took, so the card doesn't shrink under your finger when you tap one.
            ZStack {
                buttons(waitingFoot).hidden().accessibilityHidden(true)
                answeredLine(foot)
            }
        }
    }

    /// The foot the card had while it waited (what the answered line keeps the room of).
    private var waitingFoot: GoalOfferFoot {
        var waiting = model.offer
        waiting.state = "new"
        return GoalOffers.foot(waiting, past: false)
    }

    @ViewBuilder private func buttons(_ foot: GoalOfferFoot) -> some View {
        if let main = foot.main {
            VStack(spacing: 8) {   // the card's own spacing, as when these sat in it directly
                let all = [main] + foot.others
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { ForEach(all, id: \.self) { button($0) } }
                } else {
                    HStack(spacing: 8) { ForEach(all, id: \.self) { button($0).frame(maxWidth: .infinity) } }
                }
                if let quiet = foot.quiet {
                    Button { tap(quiet) } label: {
                        Text(quiet.title).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled || model.busy)
                    .accessibilityIdentifier("goal.offer-card.quiet")
                }
            }
        }
    }

    private func answeredLine(_ foot: GoalOfferFoot) -> some View {
            HStack(spacing: 7) {
                if foot.good {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TodoInk.color(.ready)).accessibilityHidden(true)
                }
                Text(foot.line ?? "Answered")
                    .font(Font.hq(.subheadline).weight(foot.good ? .semibold : .regular))
                    .foregroundStyle(foot.good ? TodoInk.color(.ready) : Color.hqLabel2)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if foot.undo {
                    Button("Undo", action: undo)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqTintText)
                        .disabled(!enabled || model.busy)
                        .accessibilityIdentifier("goal.offer-card.undo")
                }
            }
            .frame(minHeight: 34)
    }

    private func button(_ item: GoalOfferButton) -> some View {
        Button { tap(item) } label: {
            HStack(spacing: 5) {
                if model.busy, item.main { ProgressView().controlSize(.mini) }
                Text(item.title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(GoalCardButtonStyle(main: item.main))
        .disabled(!enabled || model.busy)
        .accessibilityIdentifier("goal.offer-card.\(item.title)")
    }

    private func section<Content: View>(_ header: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header {
                Text(header.uppercased())
                    .font(Font.hq(.caption2).weight(.semibold))
                    .kerning(0.4)
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
    }

    private func line<Trail: View>(_ title: String, milestone: Bool, added: Bool, gone: Bool, @ViewBuilder trail: () -> Trail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: GoalOffers.lineMark(milestone: milestone, added: added))   // [goals set-up] added, not done
                .font(Font.hq(.footnote))
                .foregroundStyle(added ? TodoInk.color(.ready) : Color.hqLabel3)
                .accessibilityHidden(true)
            Text(title)
                .font(Font.hq(.footnote))
                .strikethrough(gone)
                .foregroundStyle(gone ? Color.hqLabel2 : Color.hqLabel)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            trail()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(GoalOffers.lineState(added: added))
    }

    /// "Name   Draw every day": the label quiet at a fixed width, the value in the label's ink (struck through once the
    /// plan is undone or declined, as the plan's lines are).
    private func setupLine(_ row: GoalSetupRow, gone: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(row.label)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .frame(minWidth: typeSize.isAccessibilitySize ? nil : 58, alignment: .leading)
            Text(row.value)
                .font(Font.hq(.footnote))   // one weight in every state: the words wrap the same, the card keeps its height
                .strikethrough(gone)
                .foregroundStyle(gone ? Color.hqLabel2 : Color.hqLabel)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalOffers.setupSpoken(row))
        .accessibilityIdentifier("goal.offer-card.setup.\(row.key)")
    }

    @ViewBuilder private func trail(due: String?, bot: String?, milestone: Bool) -> some View {
        let day = TodoDates.due(due).map { TodoWords.day($0.date, now: Date()) }
        if let bot {
            HStack(spacing: 4) {
                HeadImage(raw: model.heads[bot], profile: bot, size: 14).frame(width: 14, height: 14).accessibilityHidden(true)
                Text(name(bot)).lineLimit(1)
            }
            .font(Font.hq(.caption))
            .foregroundStyle(Color.hqLabel2)
            .fixedSize()
        } else if milestone {
            if let day { Text(day).font(Font.hq(.caption)).monospacedDigit().foregroundStyle(Color.hqLabel2).fixedSize() }
        } else {
            Text(day.map { "You · \($0)" } ?? "You").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).fixedSize()
        }
    }

    private func moreLine(_ n: Int) -> some View {
        Button(action: more) {
            Text("\(n) more ›").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .accessibilityLabel("\(n) more")
        .accessibilityHint("Shows the whole card")
        .accessibilityIdentifier("goal.offer-card.more")
    }
}

/// The card's buttons: the filled one, and the outlined ones beside it (board 4's Add These 3 / Change / Not Now).
struct GoalCardButtonStyle: ButtonStyle {
    var main: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let _ = Theme.touch()
        let label = configuration.label
            .font(Font.hq(.footnote).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .opacity(enabled ? 1 : 0.45)
        if DeviceWord.isMac || Theme.isDesktop {
            let shape = RoundedRectangle(cornerRadius: DeviceWord.isMac ? MacPush.radius : DesktopRows.radius, style: .continuous)
            label
                .foregroundStyle(main ? Color.hqOnTint : Color.hqLabel)
                .background(shape.fill(main ? Color.hqTint : (DeviceWord.isMac ? MacPush.fillColor : Color.clear)))
                .overlay { if !main { shape.strokeBorder(DeviceWord.isMac ? MacPush.strokeColor : Color.hqStroke, lineWidth: HQShape.hairline) } }
                .contentShape(shape)
        } else {
            label
                .foregroundStyle(main ? Color.hqOnTint : Color.hqTintText)
                .background(Capsule().fill(main ? AnyShapeStyle(Color.hqTint) : AnyShapeStyle(Color.clear)))
                .overlay { if !main { Capsule().strokeBorder(Color.hqStroke, lineWidth: 1) } }
                .contentShape(Capsule())
        }
    }
}

// MARK: - The whole card ("N more ›")

enum GoalOfferAllSheet {
    @MainActor static func make(_ offer: TodoOffer, goal: Goal?, botName: @escaping (String?) -> String) -> UIViewController {
        let host = UIHostingController(rootView: HQScaledRoot(GoalOfferAllView(offer: offer, goal: goal, botName: botName)))
        let title = offer.title.isEmpty ? (goal?.title ?? "Goal") : offer.title
        let nav = ChatSheet.wrap(host, title: title, detents: [.medium(), .large()])
        return nav
    }
}

struct GoalOfferAllView: View {
    var offer: TodoOffer
    var goal: Goal?
    var botName: (String?) -> String

    var body: some View {
        // [goals set-up] Taken (as the store has it now): each line was added, so it has the card's plus.
        let added = (TodoOfferStates.live(offer.id).offer ?? offer).state == "accepted"
        List {
            // [goals set-up] What the plan rests on, and what accepting it also sets, as on the card.
            let builtOn = GoalOffers.builtOn(offer)
            if !builtOn.isEmpty {
                Section {
                    ForEach(Array(builtOn.enumerated()), id: \.offset) { _, words in
                        Text(words).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("goal.offer-all.built-on")
                    }
                } header: { HQSectionLabel { Text(GoalOffers.builtOnHeader) } }
            }
            let setup = GoalOffers.setupRows(offer, now: Date())
            if !setup.isEmpty {
                Section {
                    ForEach(setup, id: \.key) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(Color.hqLabel2)
                            Spacer(minLength: 12)
                            Text(row.value).multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(GoalOffers.setupSpoken(row))
                        .accessibilityIdentifier("goal.offer-all.setup.\(row.key)")
                    }
                } header: { HQSectionLabel { Text(GoalOffers.setupHeader) } }
            }
            if !offer.milestones.isEmpty {
                Section {
                    ForEach(Array(offer.milestones.enumerated()), id: \.offset) { _, m in
                        HStack {
                            mark(milestone: true, added: added)
                            Text(m.title)
                            Spacer()
                            if let day = TodoDates.due(m.due) { Text(TodoWords.day(day.date, now: Date())).foregroundStyle(Color.hqLabel2) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(GoalOffers.lineState(added: added))
                        .accessibilityIdentifier("goal.offer-all.line")
                    }
                } header: { HQSectionLabel { Text(GoalOffers.milestoneCount(offer.milestones.count)) } }
            }
            if !offer.tasks.isEmpty {
                Section {
                    ForEach(Array(offer.tasks.enumerated()), id: \.offset) { _, task in
                        HStack {
                            mark(milestone: false, added: added)
                            Text(task.title)
                            Spacer()
                            Text(GoalOffers.who(task, offer: offer, botName: botName)).foregroundStyle(Color.hqLabel2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(GoalOffers.lineState(added: added))
                        .accessibilityIdentifier("goal.offer-all.line")
                    }
                } header: { HQSectionLabel { Text(TodoLists.count(offer.tasks.count).capitalized) } }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .font(Font.hq(.callout))
        .accessibilityIdentifier("goal.offer-all")
    }

    private func mark(milestone: Bool, added: Bool) -> some View {
        Image(systemName: GoalOffers.lineMark(milestone: milestone, added: added))
            .foregroundStyle(added ? TodoInk.color(.ready) : Color.hqLabel3)
            .accessibilityHidden(true)
    }
}

// MARK: - The stall question ([goals step 4], board 4's right phone)

/// "Nothing has moved in 16 days" in orange, the question, then Smaller Step / Pause / Let It Go and a quiet Keep Going.
struct GoalStallCard: View {
    var stall: GoalStall
    var question: String
    var enabled: Bool
    var smaller: () -> Void
    var pause: () -> Void
    var letGo: () -> Void
    var keep: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GoalViews.stallLine(stall))
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqOrange)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("goal.stall.line")
            Text(question)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("goal.stall.question")
            let buttons = Group {
                Button(action: smaller) { Text("Smaller Step").frame(maxWidth: .infinity) }.buttonStyle(GoalCardButtonStyle(main: true))
                    .accessibilityHint("Adds one small first step").accessibilityIdentifier("goal.stall.smaller")
                Button(action: pause) { Text("Pause").frame(maxWidth: .infinity) }.buttonStyle(GoalCardButtonStyle(main: false))
                    .accessibilityHint("Pauses the goal").accessibilityIdentifier("goal.stall.pause")
                Button(action: letGo) { Text("Let It Go").frame(maxWidth: .infinity) }.buttonStyle(GoalCardButtonStyle(main: false))
                    .accessibilityHint("Keeps the goal under Let Go").accessibilityIdentifier("goal.stall.let-go")
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }   // equal widths: each label fills its share (board 4)
            }
            Button("Keep Going", action: keep)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
                .accessibilityHint("Asks again in two weeks")
                .accessibilityIdentifier("goal.stall.keep")
        }
        .disabled(!enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
                // A warm wash (board 4) from the orange a goal's ring is drawn in; the words keep the theme's readable
                // orange (hqOrange is darkened for 4.5:1, and a wash of it reads pink).
                .fill(TodoListColor.orange.ink.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
                        .strokeBorder(TodoListColor.orange.ink.opacity(0.3), lineWidth: HQShape.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal.stall")
    }
}
