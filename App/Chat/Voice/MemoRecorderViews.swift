// The recorder's rows inside the composer's field (spec 1x-voice §3.5; the field's glass stays, its height never
// changes) and the big red circle with its halo and the glass lock capsule, floating over the chat screen so nothing
// clips them. Every size, motion and word follows the spec: the holding row, the locked row (trash, pill with the live
// waveform, Stop), and review (trash, pill with play, 40 bars, the time).

import UIKit

enum MemoRecorderStyle {
    static func timerFont(cap: CGFloat, base: UIFont.TextStyle) -> UIFont {
        let size = min(cap, HQFont.preferred(base).pointSize)
        return HQFont.monoDigitFace(ofSize: size, weight: .semibold)
    }

    static func capped(_ style: UIFont.TextStyle, _ cap: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        HQFont.face(ofSize: min(cap, HQFont.preferred(style).pointSize), weight: weight)
    }

    /// The red dot's 1 s pulse (none under Reduce Motion).
    static func pulse(_ layer: CALayer) {
        layer.removeAnimation(forKey: "pulse")
        guard !HQMotion.reduced else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    static func button(symbol: String, size: CGFloat, color: UIColor, label: String, id: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
        config.baseForegroundColor = color
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        return button
    }
}

// MARK: - Holding

/// While the finger holds: a pulsing red dot, the timer, and "‹ Slide to cancel" (or "Release to Cancel"). The finger
/// owns this row: VoiceOver skips it.
final class MemoHoldRow: UIView {
    private let dot = UIView()
    private let timer = UILabel()
    private let slide = UIStackView()
    /// The slide label's room: it follows the finger left inside it and is clipped at its edges (never over the timer).
    private let slideRoom = UIView()
    private let chevron = UIImageView()
    private let slideLabel = UILabel()
    /// Where the big circle can reach, in this view's coordinates (the label ends 12 pt before it).
    var circleReachX: CGFloat = 0 { didSet { if circleReachX != oldValue { setNeedsLayout() } } }
    private var slideOffset: CGFloat = 0
    private var armed = false
    /// Measured when the words change, not on every layout pass (a finger moves at 60–120 Hz).
    private var slideFitWidth: CGFloat?
    private var timerWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        dot.backgroundColor = ChatPalette.alertRed
        dot.layer.cornerRadius = 5
        addSubview(dot)
        timer.font = MemoRecorderStyle.timerFont(cap: 22, base: .headline)
        timer.textColor = ChatPalette.label
        addSubview(timer)
        // Grows with "Slide to Cancel" beside it (Subheadline capped at 20), to 17.
        chevron.image = UIImage(systemName: "chevron.left",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: HQFont.symbolSize(13, like: .subheadline, cap: 17), weight: .semibold))
        chevron.tintColor = ChatPalette.label2
        chevron.contentMode = .center
        // In a tight room the words shrink a little (`minimumScaleFactor`), never the "‹" before them.
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        slideLabel.font = MemoRecorderStyle.capped(.subheadline, 20)
        slideLabel.textColor = ChatPalette.label2
        slideLabel.lineBreakMode = .byTruncatingTail
        // "Release to Cancel" stays whole: it shrinks a little before it would clip.
        slideLabel.adjustsFontSizeToFitWidth = true
        slideLabel.minimumScaleFactor = 0.8
        slide.addArrangedSubview(chevron)
        slide.addArrangedSubview(slideLabel)
        slide.axis = .horizontal
        slide.spacing = 4
        slide.alignment = .center
        slideRoom.clipsToBounds = true
        slideRoom.addSubview(slide)
        addSubview(slideRoom)
        accessibilityIdentifier = "memo.hold"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { MemoRecorderStyle.pulse(dot.layer) }
    }

    func update(seconds: Double, limit: Double, dx: Double, armed: Bool) {
        let time = MemoPolicy.length(seconds)
        if timer.text != time {
            timer.text = time
            timerWidth = nil
        }
        let timerColor = limit - seconds <= 10 ? ChatPalette.orange : ChatPalette.label
        if timer.textColor != timerColor { timer.textColor = timerColor }
        let offset = armed ? 0 : max(-56, min(0, CGFloat(dx)) * 0.5)
        if armed != self.armed || slideLabel.text == nil {
            self.armed = armed
            chevron.isHidden = armed
            UIView.transition(with: slideLabel, duration: 0.15, options: [.transitionCrossDissolve, .beginFromCurrentState]) {   // motion-ok: cross-fade
                self.slideLabel.text = armed ? "Release to Cancel" : "Slide to cancel"
                self.slideLabel.font = MemoRecorderStyle.capped(.subheadline, 20, weight: armed ? .semibold : .regular)
                self.slideLabel.textColor = armed ? ChatPalette.red : ChatPalette.label2
            }
            slideFitWidth = nil
            slideOffset = offset
            setNeedsLayout()
        } else if offset != slideOffset || timerWidth == nil {
            slideOffset = offset
            setNeedsLayout()
        }
    }

    /// What the slide label says ("Slide to cancel" / "Release to Cancel") and the timer's colour (tests).
    var slideWords: String? { slideLabel.text }
    var slideColor: UIColor { slideLabel.textColor }
    var timerColor: UIColor { timer.textColor }

    override func layoutSubviews() {
        super.layoutSubviews()
        let midY = bounds.height / 2
        dot.frame = CGRect(x: 16, y: midY - 5, width: 10, height: 10)
        let timerW = timerWidth ?? ceil(timer.sizeThatFits(CGSize(width: 200, height: bounds.height)).width)
        timerWidth = timerW
        timer.frame = CGRect(x: dot.frame.maxX + 8, y: 0, width: timerW, height: bounds.height)
        let left = timer.frame.maxX + 8
        let right = max(left, circleReachX - 12)
        slideRoom.frame = CGRect(x: left, y: 0, width: right - left, height: bounds.height)
        let fit = slideFitWidth ?? slide.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        slideFitWidth = fit
        let w = min(right - left, fit)
        slide.frame = CGRect(x: (right - left - w) / 2 + slideOffset, y: 0, width: w, height: bounds.height)
    }
}

// MARK: - Live waveform (locked)

/// The hands-free take's sound, drawn straight on the field's glass (no pill behind it): 3 pt round bars on a 5 pt
/// pitch, mirrored about the middle, the newest entering at the trailing edge. The bars fade in from the timer side and
/// run red to a hot orange-pink at the newest end, which glows with the voice. With motion on, a display link scrolls
/// them smoothly and the newest bar follows the live level (fast attack, slower fall); under Reduce Motion they step
/// once per 100 ms from the controller's levels, as before.
final class MemoLiveWave: UIView {
    static let barWidth: CGFloat = 3
    static let pitch: CGFloat = 5
    /// Seconds per bar.
    private static let step: CFTimeInterval = 0.1

    /// The controller's per-100 ms levels (the still drawing, and the seed when the moving one starts).
    private(set) var levels: [Double] = []
    /// The newest level (15 Hz).
    private var target: Double = 0
    private var running = false

    private let colors = CAGradientLayer()
    private let bars = CAShapeLayer()
    private let glow = CALayer()
    private var link: CADisplayLink?
    /// The moving drawing's own bars (newest last), its newest bar's eased level, and when that bar started.
    private var history: [CGFloat] = []
    private var head: CGFloat = 0
    private var lastFrame: CFTimeInterval = 0
    private var lastPush: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glow.shadowOffset = .zero
        glow.shadowRadius = 6
        layer.addSublayer(glow)
        colors.startPoint = CGPoint(x: 0, y: 0.5)
        colors.endPoint = CGPoint(x: 1, y: 0.5)
        colors.mask = bars
        layer.addSublayer(colors)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoLiveWave, _) in
            view.applyColors()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A new reading: `running` is false while the take is ending (the wave holds still).
    func feed(level: Double, levels: [Double], running: Bool) {
        target = min(1, max(0, level))
        self.levels = levels
        self.running = running
        syncLink()
        if link == nil { setNeedsLayout() }
    }

    private var moving: Bool { running && !isHidden && window != nil && !HQMotion.reduced }

    override var isHidden: Bool { didSet { if isHidden != oldValue { syncLink() } } }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLink()
    }

    private func syncLink() {
        if moving, link == nil {
            // Seeded from the take so far, so locking from a hold (or reopening) shows what was already said.
            history = levels.suffix(fitCount + 1).map { Self.shape($0) }
            head = Self.shape(target)
            lastFrame = CACurrentMediaTime()
            lastPush = lastFrame
            let link = CADisplayLink(target: WeakLinkTarget(self), selector: #selector(WeakLinkTarget.tick))   // motion-ok: the voice's own level, checked against Reduce Motion in `moving`
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !moving, let link {
            link.invalidate()
            self.link = nil
            setNeedsLayout()
        }
    }

    fileprivate func advance(_ now: CFTimeInterval) {
        let dt = min(0.1, max(0, now - lastFrame))
        lastFrame = now
        let goal = Self.shape(target)
        // Rises in ~35 ms, falls in ~140 ms: the bar jumps with a word and settles after it.
        let tau: CGFloat = goal > head ? 0.035 : 0.14
        head += (goal - head) * (1 - exp(-CGFloat(dt) / tau))
        if now - lastPush > 0.5 { lastPush = now }   // back from a stall: no burst of bars
        while now - lastPush >= Self.step {
            history.append(head)
            lastPush += Self.step
        }
        let keep = fitCount + 2
        if history.count > keep { history.removeFirst(history.count - keep) }
        draw(newest: head, older: history, slide: CGFloat((now - lastPush) / Self.step))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        colors.frame = bounds
        bars.frame = colors.bounds
        glow.frame = bounds
        CATransaction.commit()
        if link == nil {
            let fit = fitCount
            let shown = levels.suffix(fit).map { Self.shape($0) }
            draw(newest: nil, older: Array(shown), slide: 1)
        } else {
            advance(CACurrentMediaTime())
        }
    }

    private var fitCount: Int { max(1, Int((bounds.width + Self.pitch - Self.barWidth) / Self.pitch)) }

    /// A level as a share of the bar's travel: the room's hush stays at the floor, a voice fills it.
    static func shape(_ level: Double) -> CGFloat {
        let n = max(0, min(1, (level - 0.18) / 0.68))
        return CGFloat(pow(n, 0.8))
    }

    /// `newest` rides `slide` pitches in from the trailing edge (the moving drawing); `older` sit to its left.
    private func draw(newest: CGFloat?, older: [CGFloat], slide: CGFloat) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let minH: CGFloat = 3
        let path = CGMutablePath()
        let hot = CGMutablePath()
        var heights: [Int] = []
        func bar(_ x: CGFloat, _ value: CGFloat, index: Int) {
            guard x > -Self.barWidth, x < w else { return }
            let bh = (minH + value * (h - minH)).rounded()
            heights.append(Int(bh))
            let rect = CGRect(x: x, y: (h - bh) / 2, width: Self.barWidth, height: bh)
            path.addRoundedRect(in: rect, cornerWidth: Self.barWidth / 2, cornerHeight: Self.barWidth / 2)
            if index < 10 { hot.addRoundedRect(in: rect, cornerWidth: Self.barWidth / 2, cornerHeight: Self.barWidth / 2) }
        }
        var x: CGFloat
        if let newest {
            x = w - Self.barWidth + Self.pitch * (1 - min(1, slide))
            bar(x, newest, index: 0)
        } else {
            x = w - Self.barWidth + Self.pitch
        }
        for (i, value) in older.reversed().enumerated() {
            x -= Self.pitch
            bar(x, value, index: i + 1)
        }
        let loud = newest ?? older.last ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bars.path = path
        glow.shadowPath = hot
        glow.shadowOpacity = Float(0.25 + 0.6 * loud)
        glow.shadowRadius = 4 + 6 * loud
        CATransaction.commit()
        #if DEBUG
        // `-HQDebugMemoProbe YES` (UI tests): how many bars show and how many different heights they have.
        if VoiceDebugHooks.probe {
            isAccessibilityElement = true
            accessibilityIdentifier = "memo.live"
            accessibilityValue = "bars=\(heights.count);distinct=\(Set(heights).count)"
        }
        #endif
    }

    private func applyColors() {
        let red = ChatPalette.alertRed.resolvedColor(with: traitCollection)
        let pink = UIColor(red: 1, green: 0.22, blue: 0.48, alpha: 1)
        let ember = UIColor(red: 1, green: 0.56, blue: 0.24, alpha: 1)
        colors.colors = [red.withAlphaComponent(0).cgColor, red.withAlphaComponent(0.8).cgColor, red.cgColor,
                         pink.cgColor, ember.cgColor]
        colors.locations = [0, 0.15, 0.45, 0.75, 1]
        glow.shadowColor = pink.cgColor
    }

}

/// A display link's target that doesn't keep its view alive.
private final class WeakLinkTarget {
    weak var wave: MemoLiveWave?
    init(_ wave: MemoLiveWave) { self.wave = wave }
    @objc func tick(_ link: CADisplayLink) {
        guard let wave else { link.invalidate(); return }
        wave.advance(link.targetTimestamp)
    }
}

// MARK: - Locked and review

/// Hands-free (locked): trash, the pill (dot, timer, live waveform), Stop. In review: trash, the pill (play, the take's
/// 40 bars, the time counting down while it plays). The composer's primary shows Send.
final class MemoLockedRow: UIView {
    var onDelete: (() -> Void)?
    var onStop: (() -> Void)?
    var onPlay: (() -> Void)?

    private let trash = MemoRecorderStyle.button(symbol: "trash", size: 20, color: ChatPalette.red, label: "Delete Voice Memo", id: "memo.delete")
    private let stop = MemoRecorderStyle.button(symbol: "stop.fill", size: 18, color: ChatPalette.red, label: "Stop Recording", id: "memo.stop")
    private let pill = UIView()
    private let dot = UIView()
    private let timer = UILabel()
    private let live = MemoLiveWave()
    /// Review's play disc (a 32 pt tint disc in a 44 pt box).
    private let play = UIControl()
    private let playDisc = UIView()
    private let playGlyph = UIImageView()
    private let reviewWave = MemoWaveView()
    private let status = MemoStatusElement()
    private(set) var reviewing = false
    private var seconds: Double = 0
    /// Review's time counts down while the take plays (a display link only then).
    private var reviewLink: CADisplayLink?
    private var reviewFile: MemoFile?
    /// How many of review's bars fit beside the play disc and the time (at most 40; set by layout).
    private var reviewBars = 40

    override init(frame: CGRect) {
        super.init(frame: frame)
        trash.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        addSubview(trash)
        // No fill: the sound sits on the field's glass itself (the Fill 3 pill read as a grey box behind it).
        pill.layer.cornerCurve = .continuous
        addSubview(pill)
        dot.backgroundColor = ChatPalette.alertRed
        dot.layer.cornerRadius = 4
        // A small lit orb, not a flat dot.
        dot.layer.shadowColor = ChatPalette.alertRed.cgColor
        dot.layer.shadowOpacity = 0.9
        dot.layer.shadowRadius = 4
        dot.layer.shadowOffset = .zero
        pill.addSubview(dot)
        timer.font = MemoRecorderStyle.timerFont(cap: 20, base: .subheadline)
        timer.textColor = ChatPalette.label
        timer.isAccessibilityElement = false
        pill.addSubview(timer)
        pill.addSubview(live)
        playDisc.backgroundColor = ChatPalette.tint
        playDisc.layer.cornerRadius = 16
        playDisc.isUserInteractionEnabled = false
        play.addSubview(playDisc)
        playGlyph.contentMode = .center
        playGlyph.tintColor = .white
        playGlyph.isUserInteractionEnabled = false
        play.addSubview(playGlyph)
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
        play.isAccessibilityElement = true
        play.accessibilityTraits = .button
        play.accessibilityIdentifier = "memo.review.play"
        pill.addSubview(play)
        reviewWave.barColor = ChatPalette.label2
        reviewWave.playedColor = ChatPalette.tint
        reviewWave.restAlpha = 0.55
        reviewWave.isAccessibilityElement = false
        pill.addSubview(reviewWave)
        status.isAccessibilityElement = true
        status.accessibilityIdentifier = "memo.status"
        pill.addSubview(status)
        addSubview(stop)
        accessibilityIdentifier = "memo.locked"
        // VoiceOver reads the row as one group: "Voice memo" (locked) / "Voice memo to review".
        accessibilityContainerType = .semanticGroup
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoLockedRow, _) in view.reviewWave.barColor = ChatPalette.label2 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !reviewing { MemoRecorderStyle.pulse(dot.layer) }
    }

    /// VoiceOver: the pill's status ("Recording, 0:04"), read when focused, never announced (a spoken time would end up
    /// in the memo). Stop comes next; focus never lands on Send by itself.
    var statusElement: UIView { status }

    func showLocked(seconds: Double, limit: Double, level: Double, levels: [Double], ending: Bool) {
        stopReviewLink()
        if reviewing { reviewing = false; MemoRecorderStyle.pulse(dot.layer) }
        self.seconds = seconds
        dot.isHidden = false
        live.isHidden = false
        play.isHidden = true
        reviewWave.isHidden = true
        stop.isHidden = false
        timer.text = MemoPolicy.length(seconds)
        timer.textColor = limit - seconds <= 10 ? ChatPalette.orange : ChatPalette.label
        live.feed(level: level, levels: levels, running: !ending)
        status.read = { "Recording, \(MemoPolicy.length(seconds))" }
        for control in [trash, stop] as [UIControl] {
            control.isEnabled = !ending
            control.alpha = ending ? 0.4 : 1
        }
        accessibilityLabel = "Voice memo"
        accessibilityElements = [trash, status, stop]
        #if DEBUG
        if VoiceDebugHooks.probe { accessibilityElements = [trash, status, live, stop] }
        #endif
        setNeedsLayout()
    }

    /// The timer's colour (tests: orange in the last 10 s).
    var timerColor: UIColor { timer.textColor }

    func showReview(file: MemoFile, ending: Bool) {
        reviewing = true
        dot.layer.removeAllAnimations()
        dot.isHidden = true
        live.feed(level: 0, levels: live.levels, running: false)
        live.isHidden = true
        stop.isHidden = true
        play.isHidden = false
        reviewWave.isHidden = false
        let player = MemoPlayer.shared
        let playing = player.state(of: file.path) == .playing
        playGlyph.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        play.accessibilityLabel = playing ? "Pause Voice Memo" : "Play Voice Memo"   // as the bubble and the draft chip say
        // Up to 40 bars (spec §3.5.4), as many as the pill has room for: the waveform never runs under the time.
        let bars = reviewBars
        reviewWave.barCount = bars
        reviewWave.heights = MemoBubbleLayout.barHeights(file.peaks, count: bars)
        let duration = player.isCurrent(file.path) && player.duration > 0 ? player.duration : file.seconds
        let current = player.currentTime(file.path)
        reviewWave.played = duration > 0 ? Int((current / duration * Double(bars)).rounded()) : 0
        let partway = player.isCurrent(file.path) && (playing || current > 0)
        timer.text = partway ? MemoPolicy.length(max(0, duration - current)) : MemoPolicy.total(file.seconds)
        timer.textColor = ChatPalette.label
        status.read = { "Voice memo, \(MemoPolicy.total(file.seconds))" }
        trash.isEnabled = !ending
        trash.alpha = ending ? 0.4 : 1
        reviewFile = file
        if playing && window != nil { startReviewLink() } else { stopReviewLink() }
        accessibilityLabel = "Voice memo to review"
        accessibilityElements = [trash, play, status]
        setNeedsLayout()
    }

    private func startReviewLink() {
        guard reviewLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(reviewTick))   // motion-ok: a readout (playback position), not a move
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        reviewLink = link
    }

    private func stopReviewLink() {
        reviewLink?.invalidate()
        reviewLink = nil
    }

    @objc private func reviewTick() {
        guard reviewing, let reviewFile, window != nil else { stopReviewLink(); return }
        showReview(file: reviewFile, ending: false)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { stopReviewLink() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        trash.frame = CGRect(x: 0, y: (h - 44) / 2, width: 44, height: 44)
        let trailing: CGFloat = reviewing ? 6 : 44
        stop.frame = CGRect(x: bounds.width - 44, y: (h - 44) / 2, width: 44, height: 44)
        let pillH = max(36, min(h - 4, 36))
        let pillX = trash.frame.maxX
        let pillW = max(0, bounds.width - trailing - pillX - (reviewing ? 0 : 0))
        pill.frame = CGRect(x: pillX, y: (h - pillH) / 2, width: pillW, height: pillH)
        pill.layer.cornerRadius = pillH / 2
        let mid = pillH / 2
        let timerW = ceil(timer.sizeThatFits(CGSize(width: 200, height: pillH)).width)
        if reviewing {
            play.frame = CGRect(x: 0, y: mid - 22, width: 44, height: 44)
            playDisc.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
            playGlyph.frame = play.bounds
            timer.frame = CGRect(x: pillW - 12 - timerW, y: 0, width: timerW, height: pillH)
            let waveX = play.frame.maxX + 2
            let waveW = max(0, timer.frame.minX - 8 - waveX)
            // 2 pt bars on a 4 pt pitch: n bars need 4n − 2 pt.
            let fit = max(1, min(40, Int((waveW + 2) / 4)))
            reviewWave.frame = CGRect(x: waveX, y: mid - 12, width: min(waveW, CGFloat(fit * 4 - 2)), height: 24)
            if fit != reviewBars {
                reviewBars = fit
                if let reviewFile { showReview(file: reviewFile, ending: !trash.isEnabled) }
            }
            status.frame = CGRect(x: waveX, y: 0, width: max(0, timer.frame.maxX - waveX), height: pillH)
        } else {
            dot.frame = CGRect(x: 12, y: mid - 4, width: 8, height: 8)
            timer.frame = CGRect(x: dot.frame.maxX + 8, y: 0, width: timerW, height: pillH)
            let waveX = timer.frame.maxX + 8
            // Taller than the old pill's 24 pt now nothing frames it: the field's height less 3 pt each side.
            let waveH = max(24, min(34, h - 6))
            live.frame = CGRect(x: waveX, y: mid - waveH / 2, width: max(0, pillW - 6 - waveX), height: waveH)
            status.frame = CGRect(x: 0, y: 0, width: pillW, height: pillH)
        }
    }
}

/// An accessibility element whose label is computed when VoiceOver reads it (no `.updatesFrequently`).
final class MemoStatusElement: UIView {
    var read: (() -> String)?
    override var accessibilityLabel: String? {
        get { read?() }
        set {}
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - The floating circle and the lock

/// The 64 pt red circle centred on the mic (it follows the finger: 0.3 × dx left, the lift up to 72 pt), a 120 pt
/// radial glow behind it breathing with the level, rings that ripple out of it when the mic hears a voice, and the glass
/// lock capsule above it. Over the chat screen, so nothing clips it; it rides
/// the keyboard (re-measured every layout pass).
final class MemoRecorderOverlay: UIView {
    private let halo = UIView()
    private let haloGlow = CAGradientLayer()
    /// The ripples' layer, under the circle (each ring removes itself when it has faded).
    private let ripples = CALayer()
    private var lastRipple: CFTimeInterval = 0
    private let circle = UIView()
    private let micGlyph = UIImageView()
    private let lock: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let lockGlyph = UIImageView()
    private let chevron = UIImageView()
    /// The mic's centre in this view.
    var anchor: CGPoint = .zero { didSet { if anchor != oldValue { place() } } }
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var lockNear: Bool?
    private var haloScale: CGFloat = 1
    private(set) var shown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        halo.bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        haloGlow.type = .radial
        haloGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        haloGlow.endPoint = CGPoint(x: 1, y: 1)
        haloGlow.locations = [0, 0.5, 0.75, 1]
        haloGlow.frame = halo.bounds
        halo.layer.addSublayer(haloGlow)
        addSubview(halo)
        layer.addSublayer(ripples)
        applyGlowColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoRecorderOverlay, _) in view.applyGlowColors() }
        circle.backgroundColor = ChatPalette.alertRed
        circle.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        circle.layer.cornerRadius = 32
        circle.layer.shadowColor = ChatPalette.alertRed.resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoRecorderOverlay, _) in
            view.circle.layer.shadowColor = ChatPalette.alertRed.resolvedColor(with: view.traitCollection).cgColor
        }
        circle.layer.shadowOpacity = 0.35
        circle.layer.shadowRadius = 6
        circle.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(circle)
        micGlyph.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        micGlyph.tintColor = .white
        micGlyph.contentMode = .center
        micGlyph.frame = circle.bounds
        circle.addSubview(micGlyph)
        lock.bounds = CGRect(x: 0, y: 0, width: 36, height: 80)
        // The lock sits under the circle (the circle rises over it on its way to locking).
        insertSubview(lock, at: 0)
        lockGlyph.contentMode = .center
        chevron.image = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.contentMode = .center
        lock.contentView.addSubview(lockGlyph)
        lock.contentView.addSubview(chevron)
        lockGlyph.frame = CGRect(x: 0, y: 40 - 3 - 18, width: 36, height: 18)
        chevron.frame = CGRect(x: 0, y: 40 + 3, width: 36, height: 13)
        alpha = 0
        accessibilityIdentifier = "memo.overlay"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var travel: CGFloat { traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 20 : 40 }

    /// How far left the circle can reach (for the slide label's room).
    var reachX: CGFloat { anchor.x - 32 - travel }

    func show() {
        guard !shown else { return }
        shown = true
        dx = 0; dy = 0
        haloScale = 1
        place()
        setLockNear(false)
        alpha = 1
        if HQMotion.reduced {
            circle.transform = .identity
        } else {
            // 44 → 64 pt over 0.28 s with an overshoot.
            circle.transform = CGAffineTransform(scaleX: 44 / 64, y: 44 / 64)
            halo.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            lock.alpha = 0
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0,   // motion-ok: the else branch of the Reduce Motion check above
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.circle.transform = .identity
                self.halo.transform = .identity
                self.lock.alpha = 1
            }
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        ripples.sublayers?.forEach { $0.removeFromSuperlayer() }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState]) {   // motion-ok: opacity only
            self.alpha = 0
        }
    }

    /// The finger moved: the circle follows it and the lock lights up near its line. Nothing animates here.
    func move(dx: Double, dy: Double, lockNear: Bool) {
        if CGFloat(dx) != self.dx || CGFloat(dy) != self.dy {
            self.dx = CGFloat(dx)
            self.dy = CGFloat(dy)
            place()
        }
        setLockNear(lockNear)
    }

    /// A new level (15 Hz): the glow breathes with it over 90 ms (an unchanged level starts no animation), and a voice
    /// sends a ring out of the circle, more often and further the louder it is.
    func setLevel(_ level: Double) {
        let voice = MemoLiveWave.shape(level)
        if !HQMotion.reduced, voice > 0.2 {
            let now = CACurrentMediaTime()
            if now - lastRipple > Double(0.42 - 0.24 * voice), (ripples.sublayers?.count ?? 0) < 8 {
                lastRipple = now
                ripple(strength: voice)
            }
        }
        let scale = 1 + voice * 0.6
        guard scale != haloScale else { return }
        haloScale = scale
        if HQMotion.reduced {
            halo.transform = .identity
        } else {
            UIView.animate(withDuration: 0.09, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                self.halo.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }

    private func ripple(strength: CGFloat) {
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        ring.position = circle.center
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = nil
        ring.strokeColor = ChatPalette.alertRed.resolvedColor(with: traitCollection).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")   // motion-ok: only when not HQMotion.reduced (setLevel)
        grow.fromValue = 1
        grow.toValue = 1.7 + strength * 1.1
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.35 + 0.5 * strength, 0]
        fade.keyTimes = [0, 0.12, 1]
        let thin = CABasicAnimation(keyPath: "lineWidth")   // motion-ok: same ripple as grow, only when not HQMotion.reduced
        thin.fromValue = 2 + 2 * strength
        thin.toValue = 0.5
        let group = CAAnimationGroup()
        group.animations = [grow, fade, thin]
        group.duration = 0.95
        ring.add(group, forKey: "ripple")
        ripples.addSublayer(ring)
        CATransaction.commit()
    }

    private func applyGlowColors() {
        let red = ChatPalette.alertRed.resolvedColor(with: traitCollection)
        haloGlow.colors = [red.withAlphaComponent(0.5).cgColor, red.withAlphaComponent(0.24).cgColor,
                           red.withAlphaComponent(0.08).cgColor, red.withAlphaComponent(0).cgColor]
    }

    private static let lockOpen = UIImage(systemName: "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    private static let lockClosed = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))

    private func setLockNear(_ near: Bool) {
        guard near != lockNear else { return }
        lockNear = near
        lockGlyph.image = near ? Self.lockClosed : Self.lockOpen
        lockGlyph.tintColor = near ? ChatPalette.tint : ChatPalette.label2
        chevron.tintColor = ChatPalette.label2
    }

    private func place() {
        let lift = max(-72, min(0, dy))
        let center = CGPoint(x: anchor.x + max(-travel, min(0, dx) * 0.3), y: anchor.y + lift)
        circle.center = center
        halo.center = center
        // The capsule's top sits 32 + 12 + 80 pt above the mic's centre, and rides 35 % of the lift.
        lock.center = CGPoint(x: anchor.x, y: anchor.y - 32 - 12 - 40 + lift * 0.35)
    }
}
