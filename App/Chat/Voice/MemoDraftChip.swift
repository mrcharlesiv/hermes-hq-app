// The memo draft chip (spec 1x-voice §3.6): a glass capsule above the composer's field holding a memo that waits in
// this chat — play/pause, "Voice Memo 0:20" (and a status line while it loads or when it can't), and Remove. With a
// chip the mic hides and the primary shows Send: the memo goes with the field's words as the next bubble.

import UIKit

final class MemoDraftChip: UIView {
    var onRemove: (() -> Void)?
    private(set) var memo: MemoFile?

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let playButton = UIButton(type: .system)
    private let title = UILabel()
    private let status = UILabel()
    private let removeButton = UIControl()
    private let removeCircle = UIView()
    private let removeGlyph = UIImageView()
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "memo.chip"
        addSubview(glass)
        playButton.tintColor = ChatPalette.tint
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.accessibilityIdentifier = "memo.chip.play"
        glass.contentView.addSubview(playButton)
        title.font = HQFont.preferred(.subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = ChatPalette.label
        title.accessibilityIdentifier = "memo.chip.title"
        glass.contentView.addSubview(title)
        status.font = HQFont.preferred(.caption1)
        status.textColor = ChatPalette.label2
        glass.contentView.addSubview(status)
        removeCircle.backgroundColor = ChatPalette.fill2
        removeCircle.isUserInteractionEnabled = false
        removeCircle.layer.cornerRadius = 16
        removeButton.addSubview(removeCircle)
        removeGlyph.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        removeGlyph.tintColor = ChatPalette.label2
        removeGlyph.contentMode = .center
        removeGlyph.isUserInteractionEnabled = false
        removeButton.addSubview(removeGlyph)
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        removeButton.isAccessibilityElement = true
        removeButton.accessibilityTraits = .button
        removeButton.accessibilityLabel = "Remove voice memo"
        removeButton.accessibilityIdentifier = "memo.chip.remove"
        glass.contentView.addSubview(removeButton)
        observer = NotificationCenter.default.addObserver(forName: MemoPlayer.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show(_ memo: MemoFile) {
        self.memo = memo
        update()
        setNeedsLayout()
    }

    private var statusText: String {
        guard let memo else { return "" }
        let player = MemoPlayer.shared
        if player.state(of: memo.path) == .loading { return "Loading…" }
        if player.failed.contains(memo.path) { return "Couldn’t load audio" }
        return ""
    }

    private func update() {
        guard let memo else { return }
        let player = MemoPlayer.shared
        let playing = player.state(of: memo.path) == .playing
        let failed = player.failed.contains(memo.path)
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        playButton.accessibilityLabel = failed ? "Try voice memo again" : playing ? "Pause Voice Memo" : "Play Voice Memo"
        title.text = "Voice Memo \(MemoPolicy.total(memo.seconds))"
        status.text = statusText
        status.isHidden = status.text?.isEmpty ?? true
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleW = ceil(title.sizeThatFits(CGSize(width: 1000, height: 44)).width)
        let statusW = status.isHidden ? 0 : ceil(status.sizeThatFits(CGSize(width: 1000, height: 44)).width)
        return CGSize(width: min(size.width, 44 + max(titleW, statusW) + 4 + 44), height: ComposerView.memoChipHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        playButton.frame = CGRect(x: 0, y: 0, width: 44, height: bounds.height)
        removeButton.frame = CGRect(x: bounds.width - 44, y: 0, width: 44, height: bounds.height)
        removeCircle.frame = CGRect(x: 6, y: (bounds.height - 32) / 2, width: 32, height: 32)
        removeGlyph.frame = removeButton.bounds
        let textX: CGFloat = 44
        let textW = max(0, bounds.width - 44 - 44 - 4)
        let titleH = ceil(title.font.lineHeight)
        if status.isHidden {
            title.frame = CGRect(x: textX, y: (bounds.height - titleH) / 2, width: textW, height: titleH)
        } else {
            let statusH = ceil(status.font.lineHeight)
            let gap: CGFloat = 2   // [ui-sizing] the two lines touched
            let top = (bounds.height - titleH - gap - statusH) / 2
            title.frame = CGRect(x: textX, y: top, width: textW, height: titleH)
            status.frame = CGRect(x: textX, y: top + titleH + gap, width: textW, height: statusH)
        }
    }

    @objc private func playTapped() {
        guard let memo else { return }
        let path = memo.path
        MemoPlayer.shared.forgetFailure(path)
        MemoPlayer.shared.toggle(path) {
            guard FileManager.default.fileExists(atPath: path) else { throw HTTPError(status: 404, body: "missing") }
            return URL(fileURLWithPath: path)
        }
    }

    @objc private func removeTapped() {
        Haptics.play(.selection)
        if let memo, MemoPlayer.shared.isCurrent(memo.path) { MemoPlayer.shared.stop() }
        onRemove?()
    }
}
