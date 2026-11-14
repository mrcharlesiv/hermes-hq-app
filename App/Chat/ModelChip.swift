// [composer-expand] The two-row bar's model bubble: the model's name alone ("Opus 5.5") on a 36 pt capsule of Liquid
// Glass ([composer-glass], like the bar's discs), only as wide as the name (owner 2026-11-01, picking it over a bubble
// across the whole room: "the bubble width is small and it only shows the model name"). The effort lives in the panel.
// The composer centres it in the room between ☰ and the mic, so the gaps either side are always even (owner 2026-10-31:
// "more white space to the right … That can never happen"). The words always fit on one line, whatever the model is
// called (owner 2026-10-31: "guarantee this works no matter the model and provider someone uses"; two lines in the
// bubble "would be busy"): a name too long for the room takes all of it, then gives way to its form without the tag
// ("Preview", "Free"), then without its filler words ("Instruct", "2507", "FP8"); each may shrink a little first. Only
// then does the type shrink further. Nothing ends in "…" ("We do not allow that here"). A tap opens the model panel
// (`ModelPanelView`).

import UIKit

final class ModelChip: UIControl {
    /// The bubble's words: the model's name; its effort, when the model has one, is only spoken (VoiceOver, the large
    /// content viewer).
    struct Title: Equatable {
        var name: String
        var effort: String?
        /// The name without its tag ("Gemini 3 Pro" for "Gemini 3 Pro Preview"), for when even the name alone doesn't fit.
        var bareName: String? = nil
    }

    var title: Title? { didSet { if title != oldValue { relabel() } } }
    var onTap: (() -> Void)?

    private let fill = ComposerGlassDisc()
    private let label = FitLabel()
    /// [mac] In the Mac's one bordered box (`ComposerView.oneBox`) the bubble is a quiet capsule of the look's fill:
    /// glass on the box's solid surface drew nothing (owner 2026-11-08: "work in the model selector").
    var plain = false { didSet { if plain != oldValue { setNeedsLayout() } } }
    private let plainFill = UIView()
    private static let size: CGFloat = 15
    /// Room either side of the words in a bubble fitted to them (its label sits 12 pt in, so the words get 10 more).
    private static let fittedPad: CGFloat = 22

    /// The bubble's width in `room` at `height`: the name plus 22 pt either side, never narrower than a capsule twice as
    /// long as it is high (a short name like "o3" still reads as the bubble, not a disc), never wider than the room.
    /// A name that doesn't fit takes the whole room and its shorter forms (`relabel`).
    func fittedWidth(in room: CGFloat, height: CGFloat) -> CGFloat {
        guard let title, room > 0 else { return 0 }
        let words = ceil(TextFit.oneLineWidth(attributed(title.name, HQFont.system(ofSize: Self.size))))
        return min(room, max(2 * height, words + 2 * Self.fittedPad)).rounded()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        plainFill.isUserInteractionEnabled = false
        plainFill.isHidden = true
        addSubview(plainFill)
        addSubview(fill)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Model"
        accessibilityIdentifier = "composer.model"
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        // [mac] Feel list B: the bubble is wider than the app's hover reaches (72 pt); its own capsule, lit.
        PointerEffects.surface(self, capsule: true, above: fill)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (chip: ModelChip, _) in chip.relabel() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if plain { plainFill.alpha = PointerEffects.dim(isHighlighted, to: 0.6); return }
            fill.press(isHighlighted)
        }
    }

    /// While the model panel is open its words take the tint, as the thing the panel came out of. The glass stays
    /// as it is: filled with the tint it was a second blue mass beside Send (owner 2026-10-31: "too visually heavy").
    override var isSelected: Bool { didSet { if isSelected != oldValue { recolor() } } }

    private func recolor() {
        UIView.transition(with: label, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {   // motion-ok: a cross-fade
            self.relabel()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.bounds = CGRect(origin: .zero, size: bounds.size)
        fill.center = CGPoint(x: bounds.midX, y: bounds.midY)
        fill.isHidden = plain
        plainFill.isHidden = !plain
        if plain {
            plainFill.frame = bounds
            plainFill.layer.cornerRadius = bounds.height / 2
            plainFill.layer.cornerCurve = .continuous
            plainFill.backgroundColor = ChatPalette.fill3
        }
        let inset: CGFloat = 12
        label.frame = bounds.insetBy(dx: inset, dy: 0)
        relabel()
    }

    /// The first of these that fits on one line, each shrinking to 86 % at most: the name, the name without its tag,
    /// the name without its filler words. Failing all, the last shrinks as far as it must.
    private func relabel() {
        guard let title else { label.attributedText = nil; accessibilityValue = nil; return }
        let font = HQFont.system(ofSize: Self.size)
        let room = max(0, bounds.width - 24)
        var tries: [NSAttributedString] = [attributed(title.name, font)]
        if let bare = title.bareName, !bare.isEmpty, bare != title.name { tries.append(attributed(bare, font)) }
        let plain = title.bareName.flatMap { $0.isEmpty ? nil : $0 } ?? title.name
        let compact = ModelNames.compactModelName(plain)
        if compact != plain { tries.append(attributed(compact, font)) }
        var text = tries[tries.count - 1]
        if room > 0, let fits = tries.first(where: { TextFit.oneLineWidth($0) * TextFit.oneLineFloor <= room }) { text = fits }
        label.attributedText = text
        accessibilityValue = [title.name, title.effort].compactMap { $0 }.joined(separator: ", ")
        largeContentTitle = [title.name, title.effort].compactMap { $0 }.joined(separator: " ")
    }

    private func attributed(_ name: String, _ font: UIFont) -> NSAttributedString {
        NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: isSelected ? ChatPalette.tint : ChatPalette.label])
    }

    #if DEBUG
    /// Tests: the words as drawn.
    var debugLabel: FitLabel { label }
    #endif

    @objc private func tapped() {
        Haptics.play(.selection)
        onTap?()
    }
}
