// The live conversation's bar and its paused / stopped notice (docs/spec/3x-talk.md §6.1–§6.4). Both take the
// composer's place through the chat screen's dock slot, at the composer's own insets: the bar is the desktop's
// conversation controls in one row, the notice one Liquid Glass card. Every word shown comes from
// `TalkDockState`.

import AVFAudio
import UIKit

/// The glass card the notice is drawn on: radius 26, concentric with the screen's corners when it rests at the bottom.
class TalkGlassCard: UIView {
    let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    var content: UIView { glass.contentView }
    private var restsAtBottom: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(26))
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let down: Bool
        if let window {
            down = window.bounds.maxY - convert(bounds, to: window).maxY <= 10
        } else {
            down = true
        }
        guard down != restsAtBottom else { return }
        restsAtBottom = down
        glass.cornerConfiguration = down
            ? .corners(topLeftRadius: .fixed(26), topRightRadius: .fixed(26), bottomLeftRadius: .containerConcentric(minimum: 26),
                       bottomRightRadius: .containerConcentric(minimum: 26))
            : .uniformCorners(radius: .fixed(26))
    }

    private var heightCap: NSLayoutConstraint?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { heightCap?.constant = max(240, window.bounds.height * 0.6) }
    }

    /// Content taller than 60 % of the screen scrolls inside the card.
    func host(_ stack: UIView, insets: NSDirectionalEdgeInsets) {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        content.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let fit = scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
        fit.priority = UILayoutPriority(749)
        let cap = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 480)
        heightCap = cap
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            cap,
            fit,
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: insets.top),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: insets.leading),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -insets.trailing),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -insets.bottom),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }
}

// MARK: - The conversation bar

/// [talk] A view in the chat's dock slot that sits exactly where the composer's row sits (its side and bottom insets),
/// not in the question dock's card place.
protocol ComposerRowDock: UIView {}

/// The live conversation in ONE row, as the desktop draws it (`V:app/chat/composer/controls.tsx` `ConversationPill`):
///
///     [level] Listening                 [Speaker] [Mute] [Stop] [ End ]
///             Ivy · 0:03
///
/// One box at the composer's own insets: the composer's glass capsule (default look) or its one bordered box (Desktop
/// Look). Every control lies inside the box with the same inner padding, and End's corners are concentric with the
/// box's (owner, after build 308: End stuck out past the box, its round ends against square corners, and a second box
/// above made the bar heavy). A line above the box shows only for a problem (one turn's failure, with Copy Details) or
/// the speech dropped while reconnecting. The status is a word or two with the bot's name and the time under it (owner,
/// 2026-10-27: "Ivy is speaking · 0:03" in one line was cut off). The speaker button switches loudspeaker and earpiece,
/// or shows an external route's glyph and opens the system's picker; the long-press menu has the routes and Speak
/// Replies. Frames are set by hand from one measured plan (`plan(width:)`), so nothing can be pushed outside the box by
/// a stack view's required sizes.
final class TalkBarView: UIView, ComposerRowDock, UIContextMenuInteractionDelegate, HoldsOwnGlass {
    var onMute: (() -> Void)?
    var onCenter: (() -> Void)?
    var onEnd: (() -> Void)?
    /// Copy Details for one turn's failure: what to copy (read when tapped).
    var problemDetail: (() -> String?)?

    let name: String
    let route = TalkRouteButton(compact: true)

    /// Set once the first listening turn has shown "Go ahead. It sends when you pause." (`TalkListenHint`).
    static let listenHintKey = "hq.talk.listenHintSeen"
    static var listenHintSeen: Bool {
        get { UserDefaults.standard.bool(forKey: listenHintKey) }
        set { UserDefaults.standard.set(newValue, forKey: listenHintKey) }
    }

    // The notice line (only for a problem).
    private let strip = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let noticeLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private var stripCopiedTask: Task<Void, Never>?
    // The bar.
    private let box = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let visual = TalkVisualView(style: .field)
    private let titleLabel = UILabel()
    /// The second line: the bot's name, then the time (`elapsedLabel`).
    private let nameLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let speakerButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let centerButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)
    /// [live words] What the person is saying, on a row of its own above the controls (docs/spec/3x-live-words.md §4).
    private let wordsView = LiveWordsView()

    private var shown: TalkDockView?
    private var shownMuted: Bool?
    private var shownProblem: String?
    private var announced = ""
    private var hint = TalkListenHint(seen: TalkBarView.listenHintSeen)
    private var notice: String?
    private var stillVisual = false
    /// The time as "0:03"; the second line shows it as "· 0:03" after the bot's name.
    private var elapsedTime = ""
    private(set) var stacked = false
    private var applied = Plan()
    private var planned: (width: CGFloat, height: CGFloat)?

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        accessibilityIdentifier = "talk.dock"
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Voice conversation with \(name)"

        noticeLabel.font = HQFont.preferred(.footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.accessibilityIdentifier = "talk.dock.problem"
        configureIcon(copyButton, id: "talk.dock.copy", action: #selector(copyTapped))
        copyButton.accessibilityLabel = "Copy Details"
        copyButton.largeContentTitle = "Copy Details"
        strip.contentView.addSubview(noticeLabel)
        strip.contentView.addSubview(copyButton)
        strip.isHidden = true
        addSubview(strip)

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "talk.dock.title"
        titleLabel.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Audio Output") { [weak self] _ in self?.route.openPicker() ?? false },
            UIAccessibilityCustomAction(name: TalkDockState.speakRepliesLabel) { _ in
                TalkController.speaksInConversation.toggle()
                HQAnnounce.say("\(TalkDockState.speakRepliesLabel) \(TalkDockState.speakRepliesValue(TalkController.speaksInConversation))")
                return true
            },
        ]
        nameLabel.text = name
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isAccessibilityElement = false
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.accessibilityIdentifier = "talk.dock.elapsed"
        visual.isUserInteractionEnabled = false
        configureIcon(speakerButton, id: "talk.dock.speaker", action: #selector(speakerTapped))
        configureIcon(muteButton, id: "talk.dock.mute", action: #selector(muteTapped))
        configureIcon(centerButton, id: "talk.dock.center", action: #selector(centerTapped))
        endButton.accessibilityIdentifier = "talk.dock.end"
        endButton.accessibilityLabel = "End Voice Conversation"
        endButton.maximumContentSizeCategory = .accessibilityMedium
        endButton.addTarget(self, action: #selector(endTapped), for: .touchUpInside)
        route.onChange = { [weak self] in self?.routeChanged() }
        wordsView.isHidden = true
        wordsView.maxLines = 3
        for view in [wordsView, visual, titleLabel, nameLabel, elapsedLabel, route, speakerButton, muteButton, centerButton, endButton] as [UIView] {
            box.contentView.addSubview(view)
        }
        box.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(box)

        restyle()
        showSpeaker()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: TalkBarView, _) in
            bar.showNotice()
            bar.relayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (bar: TalkBarView, _) in
            bar.restyle()
            bar.showNotice()
            bar.redrawControls()
            bar.showSpeaker()
            bar.relayout()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(loudspeakerChanged), name: AudioSessionCoordinator.loudspeakerChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Reading order: the status, the time, the notice and Copy Details, then the row's buttons. Views that are hidden
    /// (Stop when it would do nothing) are left out; the route has its place in the speaker button.
    override var accessibilityElements: [Any]? {
        get {
            let all: [UIView] = [titleLabel, elapsedLabel, wordsView, noticeLabel, copyButton, speakerButton, muteButton, centerButton, endButton]
            return all.filter { view in
                var v: UIView? = view
                while let current = v, current !== self { if current.isHidden || current.alpha < 0.01 { return false }; v = current.superview }
                return true
            }
        }
        set {}
    }

    private func configureIcon(_ button: UIButton, id: String, action: Selector) {
        button.accessibilityIdentifier = id
        button.maximumContentSizeCategory = .accessibilityMedium
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: Looks

    private var desktop: Bool { Theme.boxComposer }   // [desktop-composer] the bar it stands in for
    var holdsOwnGlass: Bool { !desktop }

    /// Default look: the composer's glass, End a tinted capsule. Desktop Look: the composer's one bordered box on the
    /// editor surface (4 pt corners), flat icons, End the desktop's accent button with corners to match.
    private func restyle() {
        for glass in [box, strip] {
            if desktop {
                DesktopLayout.keepOwnLook(glass)
                if glass.effect != nil { glass.effect = nil }
                glass.backgroundColor = ChatPalette.editor
                glass.layer.borderWidth = 1
                glass.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
            } else {
                if glass.effect == nil { glass.effect = UIGlassEffect(style: .regular) }
                glass.backgroundColor = nil
                glass.layer.borderWidth = 0
            }
        }
        titleLabel.textColor = ChatPalette.label
        nameLabel.textColor = ChatPalette.label2
        elapsedLabel.textColor = ChatPalette.label2
        copyButton.configuration = iconConfig("doc.on.doc", color: ChatPalette.tint)
        setNeedsLayout()
    }

    private func iconConfig(_ symbol: String, color: UIColor, tinted: Bool = false, size: CGFloat? = nil) -> UIButton.Configuration {
        var config: UIButton.Configuration = tinted ? .tinted() : .plain()
        let points = size ?? (desktop ? 15 : 17)
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: points, weight: .medium))
        config.baseForegroundColor = color
        if tinted { config.baseBackgroundColor = ChatPalette.tint }
        config.contentInsets = .zero
        if desktop {
            config.cornerStyle = .fixed
            config.background.cornerRadius = Self.desktopInnerRadius
        } else {
            config.cornerStyle = .capsule
        }
        return config
    }

    private func redrawControls() {
        guard let shown, let muted = shownMuted else { return }
        let bar = TalkDockState.bar(shown, muted: muted)
        muteButton.configuration = iconConfig(bar.muteSymbol, color: muted ? ChatPalette.tint : ChatPalette.label, tinted: muted)
        muteButton.accessibilityLabel = bar.muteLabel
        muteButton.accessibilityTraits = muted ? [.button, .selected] : .button
        muteButton.largeContentTitle = bar.muteTitle

        // A filled glyph (stop, hand) is smaller than the outline icons beside it, so it does not read heavier.
        centerButton.configuration = iconConfig(bar.centerSymbol, color: ChatPalette.label, size: desktop ? 11 : 12)
        centerButton.accessibilityLabel = bar.centerLabel
        centerButton.largeContentTitle = bar.centerTitle
        if centerButton.isHidden == bar.showsCenter { centerButton.isHidden = !bar.showsCenter }

        var end: UIButton.Configuration = .filled()
        end.baseBackgroundColor = ChatPalette.tint
        end.baseForegroundColor = ChatPalette.onTint
        end.title = "End"
        end.titleLineBreakMode = .byClipping
        end.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = HQFont.preferred(.subheadline).withWeight(.semibold)
            return outgoing
        }
        end.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        if desktop {
            end.cornerStyle = .fixed
            end.background.cornerRadius = Self.desktopInnerRadius
        } else {
            end.cornerStyle = .capsule
        }
        endButton.configuration = end
    }

    private var speaker: TalkSpeakerButton {
        TalkDockState.speakerButton(kind: route.kind, portType: route.portType, portName: route.portName,
                                    loudspeaker: AudioSessionCoordinator.shared.loudspeaker)
    }

    /// The accent colour while the loudspeaker plays (no filled circle: that is Mute's look when muted, and the two
    /// side by side read as one state); the earpiece is the plain outline.
    private func showSpeaker() {
        let speaker = speaker
        speakerButton.configuration = iconConfig(speaker.symbol, color: speaker.on ? ChatPalette.tint : ChatPalette.label)
        speakerButton.accessibilityLabel = speaker.label
        speakerButton.accessibilityValue = speaker.value
        speakerButton.accessibilityTraits = speaker.picker ? .button : [.button, .toggleButton]
        speakerButton.largeContentTitle = speaker.label
    }

    @objc private func loudspeakerChanged() { showSpeaker() }

    private func routeChanged() {
        showSpeaker()
    }

    // MARK: Layout

    /// The look's measures: the box's height comes from End's (its inner padding all round).
    private struct Metrics {
        /// End's (and the controls') height, at the default text size.
        var control: CGFloat
        /// From the box's edge to End (and to every control's row).
        var inset: CGFloat
        /// Icon buttons: a square this wide.
        var icon: CGFloat
        /// From the box's leading edge to the level bars.
        var lead: CGFloat
        /// How far the box reaches past the bar's own frame (the Desktop Look's box, as the composer's, is 4 pt wider
        /// on each side and 3 pt taller at top and bottom than its row).
        var outset: UIEdgeInsets
    }

    private var metrics: Metrics {
        desktop ? Metrics(control: 34, inset: 6, icon: 32, lead: 12, outset: UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 4))
                : Metrics(control: 36, inset: 4, icon: 34, lead: 12, outset: .zero)
    }

    /// The Desktop Look's inner corners (End, a muted Mute): the box's 4 pt less the padding is nothing, so the
    /// desktop's smallest corner keeps them from reading as sharp.
    static let desktopInnerRadius: CGFloat = 2
    static let iconGap: CGFloat = 0
    static let endGap: CGFloat = 6
    /// Least room for the status beside the controls before they move under it.
    static let statusMinimum: CGFloat = 44

    struct Plan: Equatable {
        var height: CGFloat = 0
        var strip: CGRect?
        var box: CGRect = .zero
        var boxRadius: CGFloat = 0
        // In the box's coordinates.
        var visual: CGRect = .zero
        var title: CGRect = .zero
        var name: CGRect?
        var elapsed: CGRect?
        var speaker: CGRect = .zero
        var mute: CGRect = .zero
        var center: CGRect = .zero
        var end: CGRect = .zero
        // In the strip's coordinates.
        var notice: CGRect = .zero
        var copy: CGRect?
        var stripRadius: CGFloat = 0
        var stacked = false
        var titleLines = 1
        /// [live words] The words' row, at the top of the box.
        var words: CGRect?
    }

    private var large: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }
    private var showsHint: Bool { hint.showing && shown?.phase == .listening }

    private func applyFonts() {
        let capped = UITraitCollection(preferredContentSizeCategory: min(traitCollection.preferredContentSizeCategory, .accessibilityMedium))
        titleLabel.font = HQFont.preferred(showsHint ? .footnote : .subheadline, compatibleWith: capped)
        titleLabel.textColor = showsHint ? ChatPalette.label2 : ChatPalette.label
        nameLabel.font = HQFont.preferred(.footnote, compatibleWith: capped)
        wordsView.baseFont = HQFont.preferred(.body, compatibleWith: capped)
        elapsedLabel.font = HQFont.monoDigitFace(ofSize: HQFont.preferred(.footnote, compatibleWith: capped).pointSize)
    }

    /// [live words] New words: true when the bar's height may have changed (the owner lays the screen out again).
    @discardableResult func showWords(_ words: LiveWordsText) -> Bool {
        guard words != wordsView.text else { return false }
        wordsView.update(words, listening: false)
        relayout()
        return true
    }

    /// Everything's frame for a bar `width` wide. [live words] With words, they take a row of their own at the top of
    /// the box, as typed words do in the composer's two rows; the row of controls keeps its height under them.
    func plan(width: CGFloat) -> Plan {
        var plan = basePlan(width: width)
        guard !wordsView.text.isEmpty else { return plan }
        let lead: CGFloat = desktop ? ChatMetrics.fieldPadH : 16
        let top: CGFloat = desktop ? 10 : 14
        let wordsWidth = max(60, plan.box.width - 2 * lead)
        let wordsHeight = wordsView.height(for: wordsWidth)
        let block = top + wordsHeight + 2
        for frame in [\Plan.visual, \Plan.title, \Plan.speaker, \Plan.mute, \Plan.center, \Plan.end] { plan[keyPath: frame].origin.y += block }
        plan.name?.origin.y += block
        plan.elapsed?.origin.y += block
        plan.words = CGRect(x: lead, y: top, width: wordsWidth, height: wordsHeight)
        // Round only at the row's height: the corners stay concentric with End's.
        if !desktop { plan.boxRadius = min(plan.boxRadius, plan.box.height / 2) }
        plan.box.size.height += block
        plan.height += block
        return plan
    }

    private func basePlan(width: CGFloat) -> Plan {
        applyFonts()
        var plan = Plan()
        let m = metrics
        let gutter = m.outset.left + m.outset.right
        let boxWidth = width + gutter
        let end = endButton.intrinsicContentSize
        let control = max(m.control, ceil(end.height))
        let endWidth = max(control + 12, ceil(end.width))
        let icon = max(m.icon, control - (m.control - m.icon))

        // The notice line.
        var top: CGFloat = 0
        if notice != nil {
            let copyShown = shownProblem != nil
            // At most two lines (the whole text is under Copy Details); every line at accessibility sizes.
            noticeLabel.numberOfLines = large ? 0 : 2
            let stripWidth = boxWidth
            let lead = desktop ? 14 : ChatMetrics.fieldPadH
            let trail = copyShown ? 4 + 32 + 4 : lead
            let text = noticeLabel.sizeThatFits(CGSize(width: max(20, stripWidth - lead - trail), height: .greatestFiniteMagnitude))
            let textHeight = ceil(text.height)     // sizeThatFits keeps to numberOfLines
            let height = max(32, textHeight + 12)
            plan.strip = CGRect(x: -m.outset.left, y: 0, width: stripWidth, height: height)
            plan.notice = CGRect(x: lead, y: (height - textHeight) / 2, width: max(20, stripWidth - lead - trail), height: textHeight)
            plan.copy = copyShown ? CGRect(x: stripWidth - 4 - 32, y: (height - 32) / 2, width: 32, height: 32) : nil
            plan.stripRadius = desktop ? HQShape.desktopRadius(.field) : min(16, height / 2)
            top = height + 8 + m.outset.top
        }

        // The row, right to left: End, Stop's place (kept while it is hidden, so Mute never moves under a finger),
        // Mute, the speaker.
        func row(y: CGFloat, height: CGFloat) -> CGFloat {
            let mid = y + height / 2
            plan.end = CGRect(x: boxWidth - m.inset - endWidth, y: mid - control / 2, width: endWidth, height: control)
            var x = plan.end.minX - Self.endGap
            plan.center = CGRect(x: x - icon, y: mid - icon / 2, width: icon, height: icon)
            x = plan.center.minX - Self.iconGap
            plan.mute = CGRect(x: x - icon, y: mid - icon / 2, width: icon, height: icon)
            x = plan.mute.minX - Self.iconGap
            plan.speaker = CGRect(x: x - icon, y: mid - icon / 2, width: icon, height: icon)
            return plan.speaker.minX
        }

        let visualSize = TalkVisualView.Style.field.size
        let textX = m.lead + visualSize.width + 6
        let hinted = showsHint
        if !elapsedTime.isEmpty { elapsedLabel.text = "· \(elapsedTime)" }
        let elapsedSize = elapsedLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let nameSize = nameLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let detailHeight = ceil(max(elapsedSize.height, nameSize.height))
        // The name and the time on one line from `x`, at most `width` wide: the name gives way, the time never does.
        func detail(x: CGFloat, y: CGFloat, width: CGFloat) {
            let elapsedWidth = ceil(elapsedSize.width)
            let nameWidth = min(ceil(nameSize.width), max(0, width - 4 - elapsedWidth))
            plan.name = nameWidth >= 24 ? CGRect(x: x, y: y, width: nameWidth, height: detailHeight) : nil
            let timeX = plan.name.map { $0.maxX + 4 } ?? x
            elapsedLabel.text = plan.name == nil ? elapsedTime : "· \(elapsedTime)"
            let width = plan.name == nil ? ceil(elapsedLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width) : elapsedWidth
            plan.elapsed = CGRect(x: timeX, y: y, width: width, height: detailHeight)
        }

        let controlsLeft = row(y: 0, height: control + 2 * m.inset)
        let room = controlsLeft - 8 - textX
        plan.stacked = large || room < Self.statusMinimum

        if !plan.stacked {
            if hinted {
                // The one-time hint: two short lines in the row's height rather than a line of its own.
                let boxHeight = control + 2 * m.inset
                _ = row(y: 0, height: boxHeight)
                plan.titleLines = 2
                titleLabel.numberOfLines = 2
                titleLabel.adjustsFontSizeToFitWidth = false
                let size = titleLabel.sizeThatFits(CGSize(width: room, height: .greatestFiniteMagnitude))
                let height = min(ceil(size.height), boxHeight - 4)
                plan.title = CGRect(x: textX, y: (boxHeight - height) / 2, width: room, height: height)
                plan.box = CGRect(x: -m.outset.left, y: top - m.outset.top, width: boxWidth, height: boxHeight)
            } else {
                // The status a word or two, the name and the time under it in smaller type; the box grows if the two
                // lines need more than End's height.
                titleLabel.numberOfLines = 1
                titleLabel.adjustsFontSizeToFitWidth = true
                titleLabel.minimumScaleFactor = 0.85
                let size = titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
                let titleHeight = ceil(size.height)
                let textHeight = titleHeight + detailHeight
                let boxHeight = max(control + 2 * m.inset, textHeight + 8)
                _ = row(y: 0, height: boxHeight)
                let y = (boxHeight - textHeight) / 2
                plan.title = CGRect(x: textX, y: y, width: min(ceil(size.width), room), height: titleHeight)
                detail(x: textX, y: plan.title.maxY, width: room)
                plan.box = CGRect(x: -m.outset.left, y: top - m.outset.top, width: boxWidth, height: boxHeight)
            }
            let boxHeight = plan.box.height
            plan.boxRadius = desktop ? HQShape.desktopRadius(.field) : boxHeight / 2
            plan.visual = CGRect(x: m.lead, y: (boxHeight - visualSize.height) / 2, width: visualSize.width, height: visualSize.height)
            plan.height = top + boxHeight - m.outset.top - m.outset.bottom
            return plan
        }

        // Accessibility sizes, or a row too narrow: the status (wrapping) and the name and time over the controls, End
        // at the box's bottom trailing corner with the same padding.
        let pad: CGFloat = 10
        titleLabel.numberOfLines = 0
        plan.titleLines = 0
        titleLabel.adjustsFontSizeToFitWidth = false
        let textWidth = boxWidth - textX - m.lead
        let titleSize = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        plan.title = CGRect(x: textX, y: pad, width: textWidth, height: ceil(titleSize.height))
        plan.visual = CGRect(x: m.lead, y: pad + max(0, (min(plan.title.height, titleLabel.font.lineHeight) - visualSize.height) / 2),
                             width: visualSize.width, height: visualSize.height)
        var bottom = max(plan.title.maxY, plan.visual.maxY)
        if !hinted {
            detail(x: textX, y: bottom + 2, width: textWidth)
            bottom = plan.elapsed?.maxY ?? bottom
        }
        let rowTop = bottom + 8
        let stackedHeight = rowTop + control + m.inset
        _ = row(y: rowTop, height: control)
        plan.box = CGRect(x: -m.outset.left, y: top - m.outset.top, width: boxWidth, height: stackedHeight)
        plan.boxRadius = desktop ? HQShape.desktopRadius(.field) : control / 2 + m.inset
        plan.height = top + stackedHeight - m.outset.top - m.outset.bottom
        return plan
    }

    private func apply(_ plan: Plan) {
        applied = plan
        stacked = plan.stacked
        if let frame = plan.strip {
            strip.isHidden = false
            strip.frame = frame
            strip.cornerConfiguration = .corners(radius: .fixed(plan.stripRadius))
            if desktop { strip.layer.cornerRadius = plan.stripRadius }
            noticeLabel.frame = plan.notice
            copyButton.isHidden = plan.copy == nil
            copyButton.frame = plan.copy ?? .zero
        } else {
            strip.isHidden = true
        }
        box.frame = plan.box
        box.cornerConfiguration = .corners(radius: .fixed(plan.boxRadius))
        if desktop { box.layer.cornerRadius = plan.boxRadius }
        if let words = plan.words {
            if wordsView.isHidden {
                // In place before it fades in: it rides up with the top of the growing bar, never out of a zero frame.
                UIView.performWithoutAnimation {
                    wordsView.frame = words
                    wordsView.alpha = 0
                    wordsView.isHidden = false
                    wordsView.layoutIfNeeded()
                }
            }
            wordsView.frame = words
            wordsView.alpha = 1
        } else if !wordsView.isHidden {
            wordsView.isHidden = true
        }
        visual.frame = plan.visual
        titleLabel.frame = plan.title
        nameLabel.isHidden = plan.name == nil
        nameLabel.frame = plan.name ?? .zero
        elapsedLabel.isHidden = plan.elapsed == nil
        elapsedLabel.frame = plan.elapsed ?? .zero
        // Never drawn: kept in the window so the speaker button, the long-press menu and VoiceOver can open its picker.
        route.frame = CGRect(x: plan.speaker.minX, y: plan.speaker.minY, width: 0, height: plan.speaker.height)
        route.alpha = 0
        route.isUserInteractionEnabled = false
        route.accessibilityElementsHidden = true
        speakerButton.frame = plan.speaker
        muteButton.frame = plan.mute
        centerButton.frame = plan.center
        endButton.frame = plan.end
        if desktop {
            let color = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
            box.layer.borderColor = color
            strip.layer.borderColor = color
        }
    }

    private func relayout() {
        planned = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var fallbackWidth: CGFloat { (window?.bounds.width ?? 402) - 2 * ChatMetrics.composerSideDown }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height(for: bounds.width > 0 ? bounds.width : fallbackWidth))
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                          verticalFittingPriority: UILayoutPriority) -> CGSize {
        let width = targetSize.width > 0 && targetSize.width < 10_000 ? targetSize.width : fallbackWidth
        return CGSize(width: width, height: height(for: width))
    }

    private func height(for width: CGFloat) -> CGFloat {
        if let planned, planned.width == width { return planned.height }
        let height = plan(width: width).height
        planned = (width, height)
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let plan = plan(width: bounds.width)
        apply(plan)
        if planned?.width != bounds.width || planned?.height != plan.height {
            planned = (bounds.width, plan.height)
            invalidateIntrinsicContentSize()
        }
    }

    /// Each control answers in at least 44 × 44 pt around it; where two such areas meet, the nearer control wins.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, hit is UIControl || hit.isDescendant(of: route) { return hit }
        var best: (view: UIView, distance: CGFloat)?
        for control in [copyButton, speakerButton, muteButton, centerButton, endButton] as [UIView] {
            guard control.window != nil, !control.isHidden, control.alpha > 0.01, control.isUserInteractionEnabled,
                  control.superview.map({ !$0.isHidden && !($0.superview?.isHidden ?? false) }) ?? false else { continue }
            let frame = control.convert(control.bounds, to: self)
            let area = frame.insetBy(dx: min(0, (frame.width - 44) / 2), dy: min(0, (frame.height - 44) / 2))
            guard area.contains(point) else { continue }
            let distance = hypot(point.x - frame.midX, point.y - frame.midY)
            if best == nil || distance < best!.distance { best = (control, distance) }
        }
        guard let best else { return hit }
        if best.view === route { return route.hitTest(CGPoint(x: route.bounds.midX, y: route.bounds.midY), with: event) ?? route }
        return best.view
    }

    // MARK: The route menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // A press held on a button is that button's (its large content viewer, a slow tap), never the menu.
        let point = box.convert(location, to: self)
        for control in [speakerButton, muteButton, centerButton, endButton] as [UIView] where !control.isHidden && control.alpha > 0.01 {
            if control.convert(control.bounds, to: self).insetBy(dx: -2, dy: -2).contains(point) { return nil }
        }
        return UIContextMenuConfiguration(identifier: "talk.route" as NSString, previewProvider: nil) { [weak self] _ in self?.routeMenu() }
    }

    /// Speak Replies, then the routes the session offers (the built-in one is "Speaker"), the current one ticked, then
    /// the system's picker for everything else (AirPlay, a Bluetooth speaker that has no microphone).
    private func routeMenu() -> UIMenu {
        let routes = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                let read = await AudioWork.perform { () -> (inputs: [Input], current: String?) in
                    let session = AVAudioSession.sharedInstance()
                    let inputs = (session.availableInputs ?? []).map { Input(uid: $0.uid, type: $0.portType.rawValue, name: $0.portName) }
                    return (inputs, session.currentRoute.inputs.first?.uid)
                }
                let choices = TalkDockState.routeChoices(inputs: read.inputs.map { ($0.uid, $0.type, $0.name) }, current: read.current)
                completion(choices.map { choice in
                    UIAction(title: choice.title, image: UIImage(systemName: choice.symbol), state: choice.current ? .on : .off) { _ in
                        guard !choice.current else { return }
                        Haptics.play(.selection)
                        AudioWork.later {
                            let session = AVAudioSession.sharedInstance()
                            guard let port = session.availableInputs?.first(where: { $0.uid == choice.uid }) else { return }
                            try? session.setPreferredInput(port)
                        }
                        self?.route.refresh()
                    }
                })
            }
        }
        let more = UIAction(title: "Other Outputs…", image: UIImage(systemName: "airplayaudio")) { [weak self] _ in
            self?.route.openPicker()
        }
        // Speak Replies left the row for the speaker button (owner, 2026-10-27). It is the conversation's own switch, on
        // until switched off here, not Read Replies Aloud (tester, 2026-11-08).
        let on = TalkController.speaksInConversation
        let speak = UIAction(title: TalkDockState.speakRepliesLabel, image: UIImage(systemName: TalkDockState.speakRepliesSymbol(on)),
                             state: on ? .on : .off) { _ in
            Haptics.play(.selection)
            TalkController.speaksInConversation.toggle()
        }
        return UIMenu(title: "Audio", children: [UIMenu(options: .displayInline, children: [speak]), routes,
                                                 UIMenu(options: .displayInline, children: [more])])
    }

    private struct Input: Sendable { var uid: String; var type: String; var name: String }

    // MARK: Drawing a state

    func render(_ view: TalkDockView, muted: Bool, problem: String?, elapsed: TimeInterval) {
        let time = TalkDockState.formatElapsed(elapsed)
        if elapsedTime != time {
            let widthChanged = elapsedTime.count != time.count
            elapsedTime = time
            elapsedLabel.text = applied.name == nil ? time : "· \(time)"
            elapsedLabel.accessibilityLabel = "Elapsed \(time)"
            if widthChanged { relayout() }
        }
        guard view != shown || muted != shownMuted || problem != shownProblem else { return }
        let controlsChanged = shown.map { TalkDockState.bar($0, muted: shownMuted ?? false) } != TalkDockState.bar(view, muted: muted)
        shown = view
        shownMuted = muted
        shownProblem = problem
        if hint.observe(view.phase) { Self.listenHintSeen = true }
        titleLabel.text = TalkDockState.barStatus(view, firstHint: showsHint)
        // VoiceOver hears the state's name and its advice, whatever the row has room to show.
        titleLabel.accessibilityLabel = view.title
        titleLabel.accessibilityHint = view.hint
        notice = TalkDockState.barNotice(view, problem: problem)
        showNotice()
        switch view.visual {
        case .listen: visual.set(.listening)
        case .speak: visual.set(.speaking)
        case .muted: visual.set(.listening)
        case .think, .wait: visual.set(view.center == .spinner ? .spinner : .dots)
        }
        // Muted: the bars lie flat and faint (Mute itself shows the slashed mic; one is enough).
        stillVisual = muted
        visual.alpha = muted ? 0.4 : 1
        if muted { visual.setLevel(0) }
        if controlsChanged || muteButton.configuration == nil { redrawControls() }
        relayout()
        // Announced only when the title changes, and never over the bot's own voice (§6.1).
        if window != nil, view.phase != .speaking, announced != view.title {
            announced = view.title
            HQAnnounce.say(view.title)
        }
    }

    /// The line above the bar. A turn's failure reads in the label colour behind a small orange warning glyph (orange
    /// words on light glass were about 2.2:1, the hardest line on screen to read); the reconnect hint stays secondary.
    private func showNotice() {
        noticeLabel.accessibilityLabel = notice
        guard let notice, shownProblem != nil else {
            noticeLabel.text = notice
            noticeLabel.textColor = ChatPalette.label2
            return
        }
        let font = HQFont.preferred(.footnote, compatibleWith: traitCollection)
        noticeLabel.font = font
        noticeLabel.textColor = ChatPalette.label
        let line = NSMutableAttributedString()
        if let image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal) {
            line.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            line.append(NSAttributedString(string: " "))
        }
        line.append(NSAttributedString(string: notice))
        line.addAttributes([.font: font, .foregroundColor: ChatPalette.label], range: NSRange(location: 0, length: line.length))
        noticeLabel.attributedText = line
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The bar left while the first turn's hint showed: the hint has been seen.
        if window == nil, hint.finish() { Self.listenHintSeen = true }
    }

    func setLevel(_ level: Double) {
        visual.setLevel(stillVisual ? 0 : level)
    }

    @objc private func muteTapped() {
        Haptics.play(.selection)
        onMute?()
    }

    @objc private func centerTapped() {
        Haptics.play(shown?.center == .sendNow ? .light : .rigid)
        onCenter?()
    }

    @objc private func endTapped() {
        Haptics.play(.medium)
        onEnd?()
    }

    /// The phone's own route: loudspeaker or earpiece. Headphones, Bluetooth, CarPlay, AirPlay: the system's picker.
    @objc private func speakerTapped() {
        Haptics.play(.selection)
        if speaker.picker {
            route.openPicker()
        } else {
            AudioSessionCoordinator.shared.setLoudspeaker(!AudioSessionCoordinator.shared.loudspeaker)
        }
    }

    @objc private func copyTapped() {
        guard let text = problemDetail?() else { return }
        VoiceClipboard.copy(TalkDockState.copyText(text, events: VoiceEvents.all))
        Haptics.play(.success)   // a copy, as every Copy
        HQAnnounce.say("Copied")
        // The icon says it too: a check for two seconds, then the copy icon again (a second tap starts over).
        copyButton.configuration = iconConfig("checkmark", color: ChatPalette.tint)
        copyButton.accessibilityLabel = "Copied"
        stripCopiedTask?.cancel()
        stripCopiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.copyButton.configuration = self.iconConfig("doc.on.doc", color: ChatPalette.tint)
            self.copyButton.accessibilityLabel = "Copy Details"
        }
    }

    #if DEBUG
    var debugControls: (center: Bool, speak: Bool, copy: Bool, stacked: Bool) {
        (!centerButton.isHidden, !speakerButton.isHidden, !strip.isHidden && !copyButton.isHidden, stacked)
    }
    var debugStripShown: Bool { !strip.isHidden }
    var debugStatus: String { titleLabel.text ?? "" }
    var debugSpeaker: TalkSpeakerButton { speaker }
    /// The two lines as drawn: the status, then the name and the time (nil when not shown).
    var debugLines: (status: String, name: String?, elapsed: String?) {
        (titleLabel.text ?? "", nameLabel.isHidden ? nil : nameLabel.text, elapsedLabel.isHidden ? nil : elapsedLabel.text)
    }
    /// Whether the status and the time show their whole text (none cut off), and the name too when `name`.
    func debugTextFits(name: Bool) -> Bool {
        (name ? [titleLabel, nameLabel, elapsedLabel] : [titleLabel, elapsedLabel]).allSatisfy { label in
            label.isHidden || label.numberOfLines != 1 || label.adjustsFontSizeToFitWidth
                || ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width) <= label.bounds.width + 0.5
        }
    }
    /// The box, and End, in the bar's coordinates; End's corner radius and the box's.
    var debugEnd: (box: CGRect, end: CGRect, boxRadius: CGFloat, endRadius: CGFloat) {
        let endRadius = endButton.configuration?.cornerStyle == .capsule ? endButton.bounds.height / 2 : (endButton.configuration?.background.cornerRadius ?? 0)
        return (box.frame, endButton.convert(endButton.bounds, to: self), applied.boxRadius, endRadius)
    }
    var debugBoxInset: CGFloat { metrics.inset }
    #endif
}

// MARK: - Paused / stopped

final class TalkNoticeDock: TalkGlassCard, UITextViewDelegate, ComposerRowDock {
    var onPrimary: ((TalkNotice.Action) -> Void)?
    var onDone: (() -> Void)?

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let detailView = UITextView()
    private let primaryButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let buttons = UIStackView()
    private var detailHeight: NSLayoutConstraint!
    private var copiedTimer: Timer?
    private(set) var notice: TalkNotice?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "talk.notice"
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup

        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = HQFont.preferred(.headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "talk.notice.title"
        titleLabel.accessibilityTraits = .header
        messageLabel.font = HQFont.preferred(.subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "talk.notice.message"
        // Selectable, and it scrolls inside itself past 120 pt, so nothing is ever cut off.
        detailView.font = HQFont.preferred(.footnote)
        detailView.adjustsFontForContentSizeCategory = true
        detailView.textColor = ChatPalette.label2
        detailView.backgroundColor = .clear
        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.textContainerInset = .zero
        detailView.textContainer.lineFragmentPadding = 0
        detailView.accessibilityIdentifier = "talk.notice.detail"
        detailHeight = detailView.heightAnchor.constraint(equalToConstant: 0)
        detailHeight.isActive = true

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel, detailView])
        text.axis = .vertical
        text.spacing = 4
        // Copy Details is a small icon beside the title: a diagnostic, not a third pill as heavy as Resume.
        copyButton.accessibilityIdentifier = "talk.notice.copy"
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.maximumContentSizeCategory = .accessibilityMedium
        copyButton.showsLargeContentViewer = true
        copyButton.addInteraction(UILargeContentViewerInteraction())
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            copyButton.widthAnchor.constraint(equalToConstant: 44),
            copyButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        let top = UIStackView(arrangedSubviews: [icon, text, copyButton])
        top.axis = .horizontal
        top.alignment = .top
        top.spacing = 12
        top.setCustomSpacing(4, after: text)

        primaryButton.accessibilityIdentifier = "talk.notice.primary"
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        doneButton.accessibilityIdentifier = "talk.notice.done"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        for button in [primaryButton, doneButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            buttons.addArrangedSubview(button)
        }
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        setTitles(copied: false)

        let stack = UIStackView(arrangedSubviews: [top, buttons])
        stack.axis = .vertical
        stack.spacing = 14
        host(stack, insets: NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        arrange()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (card: TalkNoticeDock, _) in
            card.arrange()
            card.sizeDetail()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Resume (or Try Again) and Done side by side in two equal columns when both titles fit their column; else
    /// (accessibility sizes, a narrow phone) one above the other, so no title is cut.
    private func arrange() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let column = (buttons.bounds.width - buttons.spacing) / 2
        let widest = [primaryButton, doneButton].map { $0.intrinsicContentSize.width }.max() ?? 0
        let vertical = large || (buttons.bounds.width > 0 && widest > column)
        guard buttons.axis != (vertical ? .vertical : .horizontal) else { return }
        buttons.axis = vertical ? .vertical : .horizontal
        buttons.distribution = vertical ? .fill : .fillEqually
        buttons.alignment = .fill
    }

    private func pill(_ title: String, prominent: Bool) -> UIButton.Configuration {
        var config: UIButton.Configuration = prominent ? .hqProminentGlass() : .hqGlass()
        config.cornerStyle = .capsule
        config.title = title
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = HQFont.preferred(.subheadline).withWeight(.semibold)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        return config
    }

    private func setTitles(copied: Bool) {
        primaryButton.configuration = pill(notice?.action.title ?? "Resume", prominent: true)
        var copy = UIButton.Configuration.plain()
        copy.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        copy.baseForegroundColor = ChatPalette.tint
        copy.contentInsets = .zero
        copyButton.configuration = copy
        copyButton.accessibilityLabel = copied ? "Copied" : "Copy Details"
        copyButton.largeContentTitle = copyButton.accessibilityLabel
        doneButton.configuration = pill("Done", prominent: false)
    }

    func show(_ notice: TalkNotice) {
        guard notice != self.notice else { return }
        self.notice = notice
        let paused = notice.kind == .paused
        icon.image = UIImage(systemName: paused ? "pause.circle.fill" : "exclamationmark.triangle.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        icon.tintColor = paused ? .systemOrange : .systemRed
        titleLabel.text = notice.title
        messageLabel.text = notice.message
        detailView.text = notice.detail ?? ""
        detailView.isHidden = (notice.detail ?? "").isEmpty
        copiedTimer?.invalidate()
        setTitles(copied: false)
        sizeDetail()
        if window != nil {
            HQAnnounce.say("\(notice.title). \(notice.message)")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let axis = buttons.axis
        arrange()
        if buttons.axis != axis { super.layoutSubviews() }
        sizeDetail()
    }

    private func sizeDetail() {
        guard !detailView.isHidden, detailView.bounds.width > 0 else {
            if detailView.isHidden, detailHeight.constant != 0 { detailHeight.constant = 0 }
            return
        }
        let fit = detailView.sizeThatFits(CGSize(width: detailView.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(120, ceil(fit))
        detailView.isScrollEnabled = fit > 120
        if abs(detailHeight.constant - height) > 0.5 { detailHeight.constant = height }
    }

    @objc private func primaryTapped() {
        guard let notice else { return }
        Haptics.play(.light)
        onPrimary?(notice.action)
    }

    @objc private func copyTapped() {
        guard let notice else { return }
        // With the recent voice events, so a notice with no detail of its own (the meter failure) still copies what led to it.
        VoiceClipboard.copy(TalkDockState.copyText(TalkDockState.noticeText(notice), events: VoiceEvents.all))
        Haptics.play(.success)   // a copy, as every Copy
        setTitles(copied: true)
        HQAnnounce.say("Copied")
        copiedTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.setTitles(copied: false) } }
        RunLoop.main.add(timer, forMode: .common)
        copiedTimer = timer
    }

    @objc private func doneTapped() {
        onDone?()
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// The one place voice's Copy buttons write the pasteboard. A DEBUG build remembers the last text for the probe
/// (`talk.debug`, key `copied`), so a UI test reads what was copied without touching the pasteboard itself.
@MainActor enum VoiceClipboard {
    #if DEBUG
    static var last = ""
    #endif

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
        #if DEBUG
        last = text
        #endif
    }
}
