// Dictation on one chat screen (docs/spec/3x-talk.md §8): the row that takes the field's place inside the field's own
// glass (the slot the memo recorder uses), and the host that puts it there, types the words and cancels when the chat
// gives the composer up.
//
//     ( ✕ )   ● Dictating  0:07   ▂▅█▅▂                [ Done ]    (✓)

import UIKit

final class DictationRow: UIView {
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private let cancelButton = MemoRecorderStyle.button(symbol: "xmark", size: 15, color: ChatPalette.label2, label: "Cancel dictation",
                                                        id: "dictation.cancel")
    private let glyph = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let title = UILabel()
    private let time = UILabel()
    private let bars = DictationBars()
    private let doneButton = UIButton(configuration: .plain())
    /// The glyph, the title, the time and the bars as one thing VoiceOver reads ("Dictating, 0:07").
    private let status = UIView()
    private var phase = DictationController.Phase.recording
    private var shownTime = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "dictation.row"
        glyph.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        glyph.tintColor = ChatPalette.tint
        glyph.contentMode = .center
        spinner.hidesWhenStopped = true
        title.textColor = ChatPalette.label
        title.lineBreakMode = .byTruncatingTail
        time.textColor = ChatPalette.label2
        bars.tintColor = ChatPalette.tint
        status.isAccessibilityElement = true
        status.accessibilityIdentifier = "dictation.status"
        status.accessibilityTraits = .staticText
        status.isUserInteractionEnabled = false
        for view in [glyph, spinner, title, time, bars] { status.addSubview(view) }
        addSubview(status)
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        addSubview(cancelButton)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12)
        config.baseForegroundColor = ChatPalette.tint
        doneButton.configuration = config
        doneButton.accessibilityIdentifier = "dictation.done"
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        addSubview(doneButton)
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (row: DictationRow, _) in
            row.applyFonts()
            row.setNeedsLayout()
        }
        show(phase: .recording, elapsed: 0, level: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyFonts() {
        title.font = MemoRecorderStyle.capped(.subheadline, 20, weight: .semibold)
        time.font = MemoRecorderStyle.timerFont(cap: 20, base: .subheadline)
        var done = AttributedString("Done")
        done.font = MemoRecorderStyle.capped(.subheadline, 20, weight: .semibold)
        doneButton.configuration?.attributedTitle = done
    }

    /// At accessibility text sizes Done gives way (the circle does the same thing).
    private var showsDone: Bool { phase == .recording && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    /// `limit`: the take's (the last seconds count down before it).
    func show(phase: DictationController.Phase, elapsed: TimeInterval, level: Double, limit: Double = 0) {
        // Starting (a slow start, `DictationController.startingShown`) draws as Transcribing does: a spinner, no clock.
        let transcribing = phase == .transcribing || phase == .starting
        if phase != self.phase || title.text == nil {
            self.phase = phase
            title.text = phase == .starting ? "Starting…" : phase == .transcribing ? "Transcribing" : "Dictating"
            glyph.isHidden = transcribing
            if transcribing { spinner.startAnimating() } else { spinner.stopAnimating() }
            time.isHidden = transcribing
            bars.isHidden = transcribing
            setNeedsLayout()
        }
        let left = transcribing ? nil : DictationController.secondsLeft(elapsed: elapsed, limit: limit)
        let text = DictationController.clock(elapsed)
        if text != shownTime {
            shownTime = text
            time.text = text
            setNeedsLayout()
        }
        // The last seconds before the limit: orange, as the memo recorder's last ten (the controller's warning is felt).
        let timeColor = left == nil ? ChatPalette.label2 : ChatPalette.orange
        if time.textColor != timeColor { time.textColor = timeColor }
        bars.setLevel(transcribing ? 0 : level)
        status.accessibilityLabel = DictationController.spoken(phase: phase, elapsed: elapsed, limit: limit)
        doneButton.isHidden = !showsDone
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        cancelButton.frame = CGRect(x: 0, y: (height - 44) / 2, width: 44, height: 44)
        doneButton.isHidden = !showsDone
        var trailing = bounds.width
        if !doneButton.isHidden {
            let fit = doneButton.sizeThatFits(CGSize(width: bounds.width, height: 44))
            let width = max(44, ceil(fit.width))
            doneButton.frame = CGRect(x: bounds.width - width, y: (height - 44) / 2, width: width, height: 44)
            trailing = doneButton.frame.minX
        } else {
            trailing -= 12
        }
        status.frame = CGRect(x: 44, y: 0, width: max(0, trailing - 44), height: height)
        let room = status.bounds.width
        let lead = CGRect(x: 0, y: (height - 20) / 2, width: 20, height: 20)
        glyph.frame = lead
        spinner.center = CGPoint(x: lead.midX, y: lead.midY)
        var x = lead.maxX + 6
        // The time and the bars give way before the title is cut.
        let timeSize = time.isHidden ? .zero : time.sizeThatFits(CGSize(width: room, height: height))
        let barsWidth: CGFloat = bars.isHidden ? 0 : DictationBars.width
        let titleFit = title.sizeThatFits(CGSize(width: room, height: height))
        var wanted = x + ceil(titleFit.width)
        let showTime = !time.isHidden && wanted + 8 + ceil(timeSize.width) <= room
        if showTime { wanted += 8 + ceil(timeSize.width) }
        let showBars = !bars.isHidden && showTime && wanted + 10 + barsWidth <= room
        title.frame = CGRect(x: x, y: 0, width: min(ceil(titleFit.width), max(0, room - x)), height: height)
        x = title.frame.maxX
        if showTime {
            time.frame = CGRect(x: x + 8, y: 0, width: ceil(timeSize.width), height: height)
            x = time.frame.maxX
        } else {
            time.frame = .zero
        }
        bars.frame = showBars ? CGRect(x: x + 10, y: (height - DictationBars.height) / 2, width: barsWidth, height: DictationBars.height) : .zero
        accessibilityElements = doneButton.isHidden ? [cancelButton, status] : [cancelButton, status, doneButton]
    }
}

/// Five bars, weights 0.5, 0.78, 1, 0.78, 0.5 (`V:app/chat/composer/voice-activity.tsx`), driven by the recorder's meter.
final class DictationBars: UIView {
    static let weights: [Double] = [0.5, 0.78, 1, 0.78, 0.5]
    static let width: CGFloat = 5 * 3 + 4 * 3
    static let height: CGFloat = 18

    /// A bar's share of the full height at `level` (0…1): a quarter at rest, never over 93 %.
    nonisolated static func share(weight: Double, level: Double) -> Double {
        let level = max(0, min(1, level.isFinite ? level : 0))
        return 0.25 + min(0.68, level * weight)
    }

    private let layers: [CALayer] = (0..<5).map { _ in CALayer() }
    private var level = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for bar in layers {
            bar.cornerRadius = 1.5
            bar.backgroundColor = tintColor.cgColor
            layer.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for bar in layers { bar.backgroundColor = tintColor.cgColor }
    }

    func setLevel(_ level: Double) {
        self.level = max(0, min(1, level.isFinite ? level : 0))
        place(animated: !HQMotion.reduced)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(animated: false)
    }

    private func place(animated: Bool) {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.1)
        var x: CGFloat = 0
        for (index, bar) in layers.enumerated() {
            let height = max(3, bounds.height * CGFloat(Self.share(weight: Self.weights[index], level: level)))
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: 3, height: height)
            x += 6
        }
        CATransaction.commit()
    }
}

// MARK: - The host

/// Owned by the screen's `ChatVoiceHost`, which stays the one thing that touches the composer for voice.
@MainActor final class ChatDictationHost: NSObject {
    private weak var screen: ChatViewController?
    private weak var voice: ChatVoiceHost?
    private weak var chat: (any ChatVoiceTurns)?
    private lazy var row: DictationRow = {
        let row = DictationRow()
        row.onCancel = {
            Haptics.play(.rigid)   // the recording thrown away, as a memo's cancel
            DictationController.shared.cancel()
        }
        row.onDone = { DictationController.shared.done() }
        return row
    }()
    private var shown = false

    init(screen: ChatViewController, voice: ChatVoiceHost) {
        self.screen = screen
        self.voice = voice
        chat = screen.session as? ChatVoiceTurns
        super.init()
    }

    private var controller: DictationController { DictationController.shared }
    private var composer: ComposerView? { screen?.composer }
    /// A dictation records or transcribes for this chat.
    var isActive: Bool { controller.isActive(in: chat) }

    func install() {
        composer?.onStopDictation = { DictationController.shared.done() }
        composer?.onDictate = { [weak self] in self?.begin() }   // [composer-expand]
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed), name: DictationController.didChange, object: nil)
        center.addObserver(self, selector: #selector(levelChanged), name: DictationController.levelChanged, object: nil)
        center.addObserver(self, selector: #selector(wordsChanged), name: DictationController.wordsChanged, object: nil)   // [live words]
    }

    /// [live words] What this chat's dictation has heard, for the composer's words row above the dictation row
    /// (docs/spec/3x-live-words.md §3.3): "Listening…" until the first word while this device listens; once it stops,
    /// only words keep the row.
    var heard: ComposerView.Heard? {
        guard isActive else { return nil }
        let words = controller.words
        switch controller.phase {
        case .recording:
            let listening = controller.hearsWords
            return listening || !words.isEmpty ? ComposerView.Heard(words: words, listening: listening) : nil
        case .transcribing:
            return words.isEmpty ? nil : ComposerView.Heard(words: words, listening: false)
        case .idle, .starting:
            return nil
        }
    }

    /// "Dictate with Hermes" in the voice options menu, Try Again on its failure card, and [composer-expand] the mic
    /// beside Send while typing in the two-row bar.
    func begin() {
        guard let chat, let voice, voice.isAvailable, voice.isOnScreen, let composer, !composer.memoActive else { return }
        // The field's keyboard stays as it is; the words go in at the cursor when they arrive.
        controller.start(in: chat) { [weak self] words in self?.type(words) }
    }

    private func type(_ words: String) {
        guard let composer, voice?.isOnScreen == true else { return }
        composer.insertDictation(words)
    }

    /// The chat left the screen, or a question dock took the composer's place: the audio is thrown away (§8).
    func composerGone() { controller.cancel(in: chat) }

    @objc private func changed() { refresh() }

    @objc private func wordsChanged() { voice?.refreshWords() }

    @objc private func levelChanged() {
        guard shown else { return }
        row.show(phase: controller.phase, elapsed: controller.elapsed, level: controller.level, limit: controller.limit)
    }

    private func refresh() {
        guard let composer, let voice else { return }
        // The row shows once the microphone records (never for a start that the permission prompt or a failure ends at
        // once), or as "Starting…" when the start takes a while.
        let mine = isActive && (controller.phase != .starting || controller.startingShown)
        if mine {
            row.show(phase: controller.phase, elapsed: controller.elapsed, level: controller.level, limit: controller.limit)
            if composer.recorderContent !== row { composer.recorderContent = row }
            composer.dictationBusy = controller.phase == .transcribing
            composer.dictating = true
            if !shown {
                shown = true
                voice.dictationShown()
            }
        } else if shown {
            shown = false
            if composer.recorderContent === row { composer.recorderContent = nil }
            composer.dictating = false
            composer.dictationBusy = false
            voice.dictationEnded()
        }
        voice.refreshWords()   // [live words] "Listening…" with the row, the words alone once it stops
    }
}
