// The memo bubble (spec 1x-voice §5): your tint bubble holding an audio message — play disc, scrubbable waveform,
// length, 1×/1.5×/2× speed — and the transcript under it, clamped to 3 lines with More/Less. Heights are exact and
// cached like every row's; playing, progress and speed never change them (the speed's slot is reserved).

import UIKit

// MARK: - Row data

/// What a memo row needs to lay out (part of the row's variant: a change re-measures).
nonisolated struct MemoBubbleInfo: Hashable, Sendable {
    enum Words: Hashable, Sendable {
        case text(String)
        /// Your memo is still sending.
        case transcribing
        /// No transcript (failed, or none stored).
        case none
        /// Speech-to-text is off on the gateway.
        case off
        /// The send failed before a transcript.
        case sendFailed
    }
    var path: String
    var title: String
    var words: Words
    /// More was tapped.
    var open: Bool
    /// The file couldn't be fetched ("Couldn’t load audio · Try Again").
    var loadFailed: Bool

    var wordsText: String {
        switch words {
        case .text(let t): return t
        case .transcribing: return "Transcribing…"
        case .none: return "No transcript"
        case .off: return "No transcript: speech-to-text is off on your gateway."
        case .sendFailed: return "Transcription unavailable. Check the memo’s delivery status."
        }
    }

    var isTranscript: Bool { if case .text = words { return true } else { return false } }

    /// The row for a parsed memo in a user message.
    static func make(_ memo: VoiceMemo, pending: Bool, failed: Bool, open: Bool) -> MemoBubbleInfo {
        let words: Words
        switch memo.transcript {
        case .text(let t): words = .text(t)
        case .off: words = .off
        case .failed: words = .none
        case .pending: words = failed ? .sendFailed : pending ? .transcribing : .none
        }
        return MemoBubbleInfo(path: memo.path, title: memo.title, words: words, open: open,
                              loadFailed: MemoLoadFailures.contains(memo.path))
    }
}

/// Where a memo bubble's parts sit inside the bubble.
nonisolated struct MemoBubbleGeometry: @unchecked Sendable {
    var info: MemoBubbleInfo
    /// The raised card the player sits on (the play disc, the waveform, the length and the speed).
    var cardFrame: CGRect
    var cardRadius: CGFloat
    /// The 44 pt play target; the 40 pt disc is centred in it.
    var playFrame: CGRect
    var waveFrame: CGRect
    var barCount: Int
    /// Under the waveform, at its leading edge.
    var lengthFrame: CGRect
    /// The speed's 44 pt target, below the waveform (never over its bars).
    var speedFrame: CGRect
    /// The speed's capsule, in `speedFrame`'s own coordinates: under the waveform's trailing end.
    var speedCapsule: CGRect
    var failFrame: CGRect?
    var retryFrame: CGRect?
    var words: TextKitLayout
    /// The words' visible area (3 lines when clamped).
    var wordsFrame: CGRect
    var moreFrame: CGRect?
    var moreTitle: String?
    var lengthFont: UIFont
    var speedFont: UIFont
    var stateFont: UIFont
}

// MARK: - Layout

nonisolated enum MemoBubbleLayout {
    static let minWidth: CGFloat = 236
    /// The card's inset from the bubble's edge, and the play disc's inset inside the card.
    static let cardInset: CGFloat = 6
    static let cardPad: CGFloat = 8
    static let disc: CGFloat = 40
    static let waveHeight: CGFloat = 24
    /// 3 pt rounded bars with 2 pt gaps.
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2
    static var barPitch: CGFloat { barWidth + barGap }

    static func fonts(_ style: ChatStyle) -> (words: UIFont, state: UIFont, more: UIFont, length: UIFont, speed: UIFont) {
        let traits = UITraitCollection(preferredContentSizeCategory: style.category)
        let sub = HQFont.preferred(.subheadline, compatibleWith: traits)
        let foot = HQFont.preferred(.footnote, compatibleWith: traits)
        let cap = HQFont.preferred(.caption1, compatibleWith: traits)
        let more = HQFont.face(ofSize: foot.pointSize, weight: .semibold)
        // The card grows with the text under its waveform, which stops growing at 18 / 16 pt.
        let length = HQFont.monoDigitFace(ofSize: min(18, foot.pointSize), weight: .medium)
        let speed = HQFont.monoDigitFace(ofSize: min(16, cap.pointSize), weight: .semibold)
        return (sub, foot, more, length, speed)
    }

    /// Bars drawn for a waveform `width` wide, never clipped (V10).
    static func barCount(waveWidth: CGFloat) -> Int {
        max(1, min(48, Int(((waveWidth + barGap) / barPitch).rounded(.down))))
    }

    /// `count` heights 0…1 from 48 peaks (a flat track at 0.18 when unknown), clamped 0.12…1. Each bar is the loudest
    /// peak it covers, measured from the memo's own quiet level (just under its 10th-percentile bar) up to its loudest,
    /// then lifted on a curve. A phone memo (mostly quiet, a few spikes) keeps its quiet words visible; a memo that is
    /// loud throughout still shows its shape instead of a wall of full bars.
    static func barHeights(_ peaks: [Double], count: Int) -> [Double] {
        guard !peaks.isEmpty, count > 0 else { return Array(repeating: 0.18, count: max(0, count)) }
        let n = peaks.count
        let sampled: [Double] = (0..<count).map { index in
            // The peaks under this bar (at least the nearest one).
            let start = Double(index) * Double(n) / Double(count)
            let end = Double(index + 1) * Double(n) / Double(count)
            let first = min(n - 1, Int(start)), last = min(n - 1, max(first, Int(ceil(end)) - 1))
            return peaks[first...last].max() ?? 0
        }
        let loudest = sampled.max() ?? 0
        var floor = 0.8 * sampled.sorted()[count / 10]
        if loudest - floor < 0.05 { floor = 0 }   // one level throughout: show it as it is
        return sampled.map { value in
            let scaled = loudest > floor ? max(0, value - floor) / (loudest - floor) : 0
            return max(0.12, min(1, pow(scaled, 0.75)))
        }
    }

    static func make(_ b: BubbleRow, memo: MemoBubbleInfo, row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout {
        let f = fonts(style)
        let padH = ChatMetrics.bubblePadH, padV = ChatMetrics.bubblePadV
        let maxBubble = TextLayout.maxBubbleWidth(mine: true, width: width, style: style)
        let maxText = maxBubble - 2 * padH
        let color = ChatPalette.meText
        let wordsFont = memo.isTranscript ? f.words : f.state
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let wordsText = NSAttributedString(string: memo.wordsText, attributes: [.font: wordsFont, .foregroundColor: color,
                                                                                 .paragraphStyle: paragraph])
        // Natural width first, then the bubble: max(min(236, 62 % of the screen), words + 24), at most your max width.
        let natural = TextKitLayout(wordsText, width: maxText)
        let bubbleW = ceil(min(maxBubble, max(min(minWidth, (0.62 * width).rounded()), natural.size.width + 2 * padH)))
        let contentW = bubbleW - 2 * padH
        let words = abs(contentW - maxText) < 0.5 ? natural : TextKitLayout(wordsText, width: contentW)

        // The card: the play disc, then the waveform with the length (and the speed, while it plays) under it.
        let lengthLine = ceil(f.length.lineHeight)
        let speedH = max(18, ceil(f.speed.lineHeight) + 2)
        let columnH = waveHeight + 2 + max(lengthLine, speedH)
        let cardH = ceil(max(disc, columnH) + 2 * cardPad)
        let card = CGRect(x: cardInset, y: cardInset, width: bubbleW - 2 * cardInset, height: cardH)
        let discFrame = CGRect(x: card.minX + cardPad, y: card.midY - disc / 2, width: disc, height: disc)
        let playFrame = discFrame.insetBy(dx: -2, dy: -2)
        // The bars take the card's width after the disc (V10: never clipped).
        let waveX = discFrame.maxX + 10
        let bars = barCount(waveWidth: max(8, card.maxX - 12 - waveX))
        let columnY = (card.midY - columnH / 2).rounded()
        let waveFrame = CGRect(x: waveX, y: columnY, width: CGFloat(bars) * barPitch - barGap, height: waveHeight)
        let lengthW = ceil(("00:00" as NSString).size(withAttributes: [.font: f.length]).width)
        let lineY = waveFrame.maxY + 2
        let lineH = max(lengthLine, speedH)
        let lengthFrame = CGRect(x: waveX, y: lineY + (lineH - lengthLine) / 2, width: lengthW, height: lengthLine)
        // The speed's capsule ends where the bars end; its 44 pt target starts under them, so a tap on the bars seeks.
        let capsuleW = ceil(("1.5×" as NSString).size(withAttributes: [.font: f.speed]).width) + 14
        let capsule = CGRect(x: waveFrame.maxX - capsuleW, y: lineY + (lineH - speedH) / 2, width: capsuleW, height: speedH)
        let speedW = max(44, capsuleW + 8)
        let speedFrame = CGRect(x: capsule.midX - speedW / 2, y: waveFrame.maxY, width: speedW, height: 44)
        let speedCapsule = capsule.offsetBy(dx: -speedFrame.minX, dy: -speedFrame.minY)
        var y = card.maxY

        // "Couldn’t load audio · Try Again" on its own line.
        var failFrame: CGRect?, retryFrame: CGRect?
        if memo.loadFailed {
            y += 4
            let failW = ceil(("Couldn’t load audio" as NSString).size(withAttributes: [.font: f.state]).width)
            // 32 pt, or the words' own line at the largest sizes; Try Again's target is centred on it.
            let lineH = max(32, ceil(f.state.lineHeight) + 4)
            let retryW = max(44, ceil(("Try Again" as NSString).size(withAttributes: [.font: f.more]).width) + 20)
            // The words give way to the button, which keeps its whole label.
            let shownFailW = max(0, min(failW, contentW - retryW - 2))
            failFrame = CGRect(x: padH, y: y, width: shownFailW, height: lineH)
            let retryH = max(44, lineH)
            retryFrame = CGRect(x: padH + shownFailW + 2, y: y - (retryH - lineH) / 2, width: retryW, height: retryH)
            y += lineH
        }

        // The words 7 pt under the card (the card's edge is the divider), 3 lines unless open.
        y += 7
        let lines = lineRects(words)
        let clampable = memo.isTranscript && lines.count > 3
        var visibleH = words.size.height
        var lastLineMaxX = words.lastLineMaxX
        if clampable && !memo.open {
            visibleH = ceil(lines[2].maxY)
            lastLineMaxX = ceil(lines[2].maxX)
        }
        let wordsFrame = CGRect(x: padH, y: y, width: contentW, height: visibleH)
        y += visibleH

        // The bubble's time in its bottom-trailing corner, on the last laid-out line (spec 06 §2.3).
        let timeText = HQShape.showsTime(mine: b.mine) ? b.time.map(ChatRowBuilder.clock) : nil   // [desktoplook]
        let timeSize = timeText.map { CGSize(width: ceil(($0 as NSString).size(withAttributes: [.font: style.time]).width),
                                             height: style.timeLineHeight) } ?? .zero
        // Clear of a round corner (Theme › Bubble Corners).
        let timeShift = timeText == nil ? 0 : ChatMetrics.timeShift(mine: true, joinsBelow: b.joinsBelow, tail: b.tail)
        let reserve = timeText == nil ? 0 : timeSize.width + ChatMetrics.timeReserveGap + timeShift
        var moreFrame: CGRect?, moreTitle: String?
        if clampable {
            moreTitle = memo.open ? "Less" : "More"
            // A 30 pt line (taller at the largest sizes, so the word fits it), a 44 pt target centred on it; the time
            // shares it.
            let line = max(30, ceil(f.more.lineHeight) + 4)
            let target = max(44, line)
            moreFrame = CGRect(x: padH - 10, y: y - (target - line) / 2,
                               width: max(44, ceil((moreTitle! as NSString).size(withAttributes: [.font: f.more]).width) + 20), height: target)
            y += line
        } else if reserve > 0 && lastLineMaxX + reserve > contentW {
            y += style.timeLineHeight + 4
        }
        let bubbleH = ceil(y + padV)
        let gap = max(0, row.gapAbove)
        let x = width - ChatMetrics.sideInset - bubbleW
        let timeFrame = CGRect(x: bubbleW - ChatMetrics.timeTrailing - timeShift - timeSize.width,
                               y: bubbleH - ChatMetrics.timeBottom - timeShift - timeSize.height, width: timeSize.width, height: timeSize.height)
        let shape = BubbleShape.Key(width: bubbleW, height: bubbleH, mine: true, joinsAbove: b.joinsAbove, joinsBelow: b.joinsBelow, tail: b.tail)
        // Concentric with the bubble's corner, never sharper than 8 pt; in the iOS look never rounder than the bubble
        // either (Theme › Bubble Corners under 8).
        let bubbleRadius = ChatMetrics.bubbleRadius
        let cardRadius = ThemeTable.desktopLook ? max(8, bubbleRadius - cardInset) : min(bubbleRadius, max(8, bubbleRadius - cardInset))
        let geometry = MemoBubbleGeometry(info: memo, cardFrame: card, cardRadius: cardRadius, playFrame: playFrame,
                                          waveFrame: waveFrame, barCount: bars, lengthFrame: lengthFrame, speedFrame: speedFrame,
                                          speedCapsule: speedCapsule, failFrame: failFrame, retryFrame: retryFrame,
                                          words: words, wordsFrame: wordsFrame, moreFrame: moreFrame,
                                          moreTitle: moreTitle, lengthFont: f.length, speedFont: f.speed, stateFont: f.state)
        var layout = BubbleLayout(frame: CGRect(x: x, y: gap, width: bubbleW, height: bubbleH), shape: shape, mine: true, blocks: [],
                                  timeText: timeText, timeFrame: timeFrame, dimmed: false,
                                  copyText: memo.isTranscript ? memo.wordsText : memo.title, showMoreFrame: nil)
        layout.memo = geometry
        return RowLayout(height: gap + bubbleH, content: .bubble(layout))
    }

    /// Each line fragment's used rect, top to bottom.
    static func lineRects(_ layout: TextKitLayout) -> [CGRect] {
        var rects: [CGRect] = []
        let range = layout.manager.glyphRange(for: layout.container)
        layout.manager.enumerateLineFragments(forGlyphRange: range) { _, used, _, _, _ in rects.append(used) }
        return rects
    }
}

// MARK: - Playback context (which gateway a bubble's memo comes from)

/// The chat screens register how their memos are fetched (client and profile, by layout scope); a bubble asks here.
@MainActor enum MemoPlaybackContexts {
    struct Context {
        weak var client: (any GatewayClient)?
        var profile: String?
        /// `gateway.ready.performance`'s waveform route, when the gateway offers it.
        var waveformRoute: String?
        var epoch: String
    }
    private static var contexts: [String: Context] = [:]

    static func register(scope: String, client: any GatewayClient, profile: String?) {
        let ready = client.latestReady
        let features = PerformanceFeatures(ready: ready)
        contexts[scope] = Context(client: client, profile: profile,
                                  waveformRoute: features?.mediaWaveform == true ? features?.routeName : nil,
                                  epoch: ready?["replay_epoch"]?.string ?? "")
        if contexts.count > 32 { contexts = contexts.filter { $0.value.client != nil } }
    }

    static func context(_ scope: String) -> Context? { contexts[scope] }

    /// A local file for `path`: the recording itself, a cached copy, or a download through the chat's gateway.
    static func resolver(path: String, scope: String) -> @MainActor () async throws -> URL {
        { () async throws -> URL in
            guard let cache = MemoAccountStores.shared.cache else { throw HTTPError(status: 401, body: "signed out") }
            if let local = cache.local(for: path) { return local }
            guard let context = contexts[scope], let client = context.client else { throw HTTPError(status: 503, body: "no gateway") }
            do {
                let url = try await cache.fetch(path, profile: context.profile, client: client)
                // An account switch while it downloaded: the file belongs to the account that left.
                guard MemoAccountStores.shared.cache === cache else { throw CancellationError() }
                return url
            } catch let error as HTTPError {
                MemoPlayer.shared.markFailed(path)
                throw error
            }
        }
    }

    /// Loads `path`'s waveform into the shape store (plugin first, else fetch + compute off the main thread).
    static func loadShape(path: String, scope: String) -> Task<(peaks: [Double], seconds: Double), any Error>? {
        guard let shapes = MemoAccountStores.shared.shapes, shapes.shape(for: path) == nil, !shapes.failed.contains(path),
              !MemoLoadFailures.contains(path) else { return nil }
        let context = contexts[scope]
        let client = context?.client
        let route = context?.waveformRoute
        let epoch = context?.epoch ?? ""
        let profile = context?.profile
        let cache = MemoAccountStores.shared.cache
        let task = MemoWaveformQueue.shared.load(path) {
            if let client, let route,
               let plugin = try? await MemoWaveform.fromPlugin(path: path, profile: profile, route: route, client: client, epoch: epoch) {
                return plugin
            }
            guard let cache else { throw MemoWaveform.Failure(description: "signed out") }
            let url: URL
            if let local = cache.local(for: path) {
                url = local
            } else {
                guard let client else { throw MemoWaveform.Failure(description: "no gateway") }
                url = try await cache.fetch(path, profile: profile, client: client)
            }
            return try await computeOffMain(url)
        }
        Task { @MainActor in
            do {
                let shape = try await task.value
                MemoAccountStores.shared.shapes?.remember(path, peaks: shape.peaks, seconds: shape.seconds)
            } catch is CancellationError {
            } catch let error as HTTPError where error.status == 404 {
                MemoAccountStores.shared.shapes?.markFailed(path)
                MemoPlayer.shared.markFailed(path)
            } catch {
                MemoAccountStores.shared.shapes?.markFailed(path)
            }
        }
        return task
    }

    @concurrent
    private static func computeOffMain(_ url: URL) async throws -> (peaks: [Double], seconds: Double) {
        try MemoWaveform.compute(url)
    }
}

// MARK: - The view inside the bubble

/// The audio message drawn inside your bubble. Every frame comes from `MemoBubbleGeometry`.
final class MemoBubbleView: UIView {
    var onToggleMore: (() -> Void)?
    private(set) var geometry: MemoBubbleGeometry?
    private var scope = ""

    private let card = UIView()
    private let playButton = UIControl()
    private let disc = CAShapeLayer()
    private let playGlyph = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let wave = MemoWaveView()
    private let lengthLabel = UILabel()
    private let speedButton = UIControl()
    private let speedCapsule = UIView()
    private let speedLabel = UILabel()
    private let failLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let wordsView = TextDrawView()
    private let moreButton = UIButton(type: .system)
    private var link: CADisplayLink?
    /// The waveform's scrub. Only it is gated (horizontal drags only); the table's own pan is never touched, so a
    /// vertical drag that starts on a memo scrolls the chat.
    private let scrubPan = UIPanGestureRecognizer()
    private let scrubGate = ScrubPanGate()
    private var scrubFraction: Double?
    private var shapeTask: Task<(peaks: [Double], seconds: Double), any Error>?
    private var shapePath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        card.isUserInteractionEnabled = false
        card.layer.cornerCurve = .continuous
        card.backgroundColor = Self.onInk(light: 0.15, dark: 0.06)
        addSubview(card)
        // The disc stands on the card: a soft shadow under it.
        disc.shadowColor = UIColor.black.cgColor
        disc.shadowOpacity = 0.22
        disc.shadowRadius = 3
        disc.shadowOffset = CGSize(width: 0, height: 1.5)
        playButton.layer.addSublayer(disc)
        playGlyph.contentMode = .center
        playGlyph.isUserInteractionEnabled = false
        playButton.addSubview(playGlyph)
        spinner.color = ChatPalette.meBubble
        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        playButton.addSubview(spinner)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.isAccessibilityElement = true
        playButton.accessibilityTraits = .button
        playButton.accessibilityIdentifier = "memo.play"
        addSubview(playButton)

        addSubview(wave)
        let tap = UITapGestureRecognizer(target: self, action: #selector(waveTapped(_:)))
        wave.addGestureRecognizer(tap)
        scrubPan.addTarget(self, action: #selector(wavePanned(_:)))
        scrubPan.delegate = scrubGate
        wave.addGestureRecognizer(scrubPan)
        wave.onAdjust = { [weak self] step in self?.adjust(by: step) }

        lengthLabel.textColor = ChatPalette.meText.withAlphaComponent(0.85)
        lengthLabel.textAlignment = .left
        lengthLabel.isAccessibilityElement = false
        addSubview(lengthLabel)

        speedCapsule.backgroundColor = Self.onInk(light: 0.22, dark: 0.1)
        speedCapsule.isUserInteractionEnabled = false
        speedCapsule.layer.cornerCurve = .continuous
        speedLabel.textColor = ChatPalette.meText
        speedLabel.textAlignment = .center
        speedCapsule.addSubview(speedLabel)
        speedButton.addSubview(speedCapsule)
        speedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        speedButton.isAccessibilityElement = true
        speedButton.accessibilityTraits = .button
        speedButton.accessibilityIdentifier = "memo.speed"
        addSubview(speedButton)

        failLabel.textColor = ChatPalette.meText
        failLabel.text = "Couldn’t load audio"
        addSubview(failLabel)
        retryButton.setTitle("Try Again", for: .normal)
        retryButton.tintColor = ChatPalette.meText
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "memo.retry"
        addSubview(retryButton)

        wordsView.clipsToBounds = true
        wordsView.isUserInteractionEnabled = false
        wordsView.isAccessibilityElement = true
        wordsView.accessibilityIdentifier = "memo.transcript"
        addSubview(wordsView)
        moreButton.tintColor = ChatPalette.meText
        moreButton.contentHorizontalAlignment = .left
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        addSubview(moreButton)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(playerChanged(_:)), name: MemoPlayer.didChange, object: nil)
        center.addObserver(self, selector: #selector(shapesChanged(_:)), name: MemoShapeStore.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoBubbleView, _) in
            view.updatePlayback()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bubble's text colour at `light` alpha where it's white-ish (a tint bubble), `dark` where it's dark (the
    /// Desktop Look's text on a pale box), so the card and the capsule read the same on both.
    private static func onInk(light: CGFloat, dark: CGFloat) -> UIColor {
        UIColor { traits in
            let ink = ChatPalette.meText.resolvedColor(with: traits)
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1
            ink.getRed(&r, green: &g, blue: &b, alpha: nil)
            return ink.withAlphaComponent(0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 ? light : dark)
        }
    }

    /// The play glyph's colour: the bubble's fill, made solid over the page where the fill is see-through.
    private func glyphColor() -> UIColor {
        let fill = ChatPalette.meBubble.resolvedColor(with: traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard fill.getRed(&r, green: &g, blue: &b, alpha: &a), a < 0.99 else { return fill }
        var pr: CGFloat = 1, pg: CGFloat = 1, pb: CGFloat = 1
        ChatPalette.page.resolvedColor(with: traitCollection).getRed(&pr, green: &pg, blue: &pb, alpha: nil)
        return UIColor(red: r * a + pr * (1 - a), green: g * a + pg * (1 - a), blue: b * a + pb * (1 - a), alpha: 1)
    }

    isolated deinit {
        link?.invalidate()
        if let shapePath, shapeTask != nil { MemoWaveformQueue.shared.leave(shapePath) }
    }

    // MARK: Configure

    func configure(_ g: MemoBubbleGeometry, scope: String, speaker: String?) {
        let pathChanged = geometry?.info.path != g.info.path
        if pathChanged { leaveShape() }
        geometry = g
        self.scope = scope
        card.frame = g.cardFrame
        card.layer.cornerRadius = g.cardRadius
        playButton.frame = g.playFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.frame = playButton.bounds
        let d = MemoBubbleLayout.disc
        let oval = UIBezierPath(ovalIn: CGRect(x: (g.playFrame.width - d) / 2, y: (g.playFrame.height - d) / 2, width: d, height: d)).cgPath
        disc.path = oval
        disc.shadowPath = oval
        CATransaction.commit()
        playGlyph.frame = playButton.bounds
        spinner.center = CGPoint(x: playButton.bounds.midX, y: playButton.bounds.midY)
        wave.frame = g.waveFrame
        wave.barWidth = MemoBubbleLayout.barWidth
        wave.barGap = MemoBubbleLayout.barGap
        wave.barHeightRange = 3...MemoBubbleLayout.waveHeight
        wave.restAlpha = 0.42
        wave.barCount = g.barCount
        lengthLabel.frame = g.lengthFrame
        lengthLabel.font = g.lengthFont
        speedButton.frame = g.speedFrame
        speedLabel.font = g.speedFont
        speedCapsule.frame = g.speedCapsule
        speedCapsule.layer.cornerRadius = g.speedCapsule.height / 2
        speedLabel.frame = speedCapsule.bounds
        if let fail = g.failFrame, let retry = g.retryFrame {
            failLabel.isHidden = false
            retryButton.isHidden = false
            failLabel.frame = fail
            failLabel.font = g.stateFont
            retryButton.frame = retry
            retryButton.titleLabel?.font = HQFont.face(ofSize: g.stateFont.pointSize, weight: .semibold)
        } else {
            failLabel.isHidden = true
            retryButton.isHidden = true
        }
        wordsView.frame = g.wordsFrame
        wordsView.set(layout: g.words)
        wordsView.accessibilityLabel = (speaker.map { "\($0) said: " } ?? "") + g.info.wordsText
        if let more = g.moreFrame, let title = g.moreTitle {
            moreButton.isHidden = false
            moreButton.frame = more
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: HQFont.face(ofSize: g.stateFont.pointSize, weight: .semibold), .foregroundColor: ChatPalette.meText,
            ]))
            moreButton.configuration = config
            moreButton.accessibilityLabel = title == "More" ? "Show the whole transcript" : "Show less of the transcript"
        } else {
            moreButton.isHidden = true
        }
        updateShape()
        updatePlayback()
        if window != nil { requestShapeIfNeeded() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLink()
            leaveShape()
        } else {
            requestShapeIfNeeded()
            updatePlayback()
        }
    }

    /// The cell now draws a text bubble: this view is hidden and forgets its memo (no display link, no waveform
    /// request, no stale playback observing).
    func reset() {
        stopLink()
        leaveShape()
        scrubFraction = nil
        geometry = nil
    }

    /// Showing a memo (a hidden view in a reused cell has none).
    private var isLive: Bool { !isHidden && geometry != nil }

    // MARK: State

    private var path: String { geometry?.info.path ?? "" }

    private var shape: MemoShape? { MemoAccountStores.shared.shapes?.shape(for: path) }

    private var duration: Double {
        let player = MemoPlayer.shared
        if player.isCurrent(path), player.duration > 0 { return player.duration }
        return shape?.seconds ?? 0
    }

    private func updateShape() {
        guard let g = geometry else { return }
        wave.heights = MemoBubbleLayout.barHeights(shape?.peaks ?? [], count: g.barCount)
        updateTime()
    }

    private func updatePlayback() {
        guard isLive else { stopLink(); return }
        let player = MemoPlayer.shared
        let state = player.state(of: path)
        let playing = state == .playing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.fillColor = ChatPalette.meText.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        let glyph = glyphColor()
        playGlyph.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: config)?
            .withTintColor(glyph, renderingMode: .alwaysOriginal)
        // The triangle's weight sits left of its box: nudged right so it looks centred in the disc.
        playGlyph.frame = playButton.bounds.offsetBy(dx: playing ? 0 : 1.5, dy: 0)
        spinner.color = glyph
        if state == .loading {
            playGlyph.isHidden = true
            spinner.startAnimating()
        } else {
            playGlyph.isHidden = false
            spinner.stopAnimating()
        }
        playButton.accessibilityLabel = playing ? "Pause Voice Memo" : "Play Voice Memo"
        let speed = player.speed
        let showSpeed = (playing || speed != 1) && geometry?.info.loadFailed != true
        speedButton.isHidden = !showSpeed
        speedLabel.text = Self.speedLabel(speed)
        speedButton.accessibilityLabel = "Playback speed \(Self.speedLabel(speed)). Change"
        if playing && window != nil { startLink() } else { stopLink() }
        updateTime()
    }

    static func speedLabel(_ speed: Double) -> String { speed == 1.5 ? "1.5×" : "\(Int(speed))×" }

    private func updateTime() {
        let player = MemoPlayer.shared
        let current = scrubFraction.map { $0 * duration } ?? player.currentTime(path)
        let total = duration
        let partway = player.isCurrent(path) && (player.state == .playing || current > 0)
        // Partway: the time left (a running clock, rounded down); at rest: the memo's rounded total.
        if total <= 0 {
            lengthLabel.text = "–:––"
        } else {
            lengthLabel.text = partway ? MemoPolicy.length(max(0, total - current)) : MemoPolicy.total(total)
        }
        let progress = scrubFraction ?? (total > 0 && player.isCurrent(path) ? current / total : 0)
        wave.progress = progress
        wave.accessibilityValue = "\(MemoPolicy.length(current)) of \(total > 0 ? MemoPolicy.total(total) : "unknown length")"
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick)) // motion-ok: the playback time readout, not decoration
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { updateTime() }

    @objc private func playerChanged(_ note: Notification) {
        guard isLive else { return }
        let changed = note.userInfo?[MemoPlayer.pathKey] as? String
        guard changed == nil || changed == path || !MemoPlayer.shared.isCurrent(path) else { return }
        updatePlayback()
    }

    @objc private func shapesChanged(_ note: Notification) {
        guard isLive, (note.userInfo?[MemoShapeStore.pathKey] as? String) == path else { return }
        updateShape()
    }

    // MARK: Waveform loading (visible bubbles only)

    private func requestShapeIfNeeded() {
        guard isLive, shapeTask == nil, !path.isEmpty, shape == nil else { return }
        shapeTask = MemoPlaybackContexts.loadShape(path: path, scope: scope)
        shapePath = shapeTask == nil ? nil : path
    }

    private func leaveShape() {
        if let shapePath, shapeTask != nil { MemoWaveformQueue.shared.leave(shapePath) }
        shapeTask = nil
        shapePath = nil
    }

    // MARK: Actions

    private var resolver: @MainActor () async throws -> URL { MemoPlaybackContexts.resolver(path: path, scope: scope) }

    @objc private func playTapped() {
        guard !path.isEmpty else { return }
        MemoPlayer.shared.toggle(path, resolve: resolver)
    }

    @objc private func speedTapped() {
        Haptics.play(.selection)
        MemoPlayer.shared.cycleSpeed()
    }

    @objc private func retryTapped() {
        MemoAccountStores.shared.shapes?.unmarkFailed(path)
        MemoPlayer.shared.forgetFailure(path)
        MemoPlayer.shared.play(path, resolve: resolver)
    }

    @objc private func moreTapped() {
        Haptics.play(.selection)
        onToggleMore?()
    }

    private func fraction(at point: CGPoint) -> Double {
        guard wave.bounds.width > 0 else { return 0 }
        return Double(max(0, min(1, point.x / wave.bounds.width)))
    }

    @objc private func waveTapped(_ gr: UITapGestureRecognizer) {
        MemoPlayer.shared.seek(path, to: fraction(at: gr.location(in: wave)), resolve: resolver)
    }

    @objc private func wavePanned(_ gr: UIPanGestureRecognizer) {
        let f = fraction(at: gr.location(in: wave))
        switch gr.state {
        case .began, .changed:
            scrubFraction = f
            updateTime()
        case .ended:
            scrubFraction = nil
            MemoPlayer.shared.seek(path, to: f, resolve: resolver)
            updateTime()
        default:
            scrubFraction = nil
            updateTime()
        }
    }

    /// VoiceOver's adjustable waveform: ±5 s.
    private func adjust(by step: Double) {
        let total = duration
        guard total > 0 else { return }
        let current = MemoPlayer.shared.currentTime(path)
        MemoPlayer.shared.seek(path, to: max(0, min(total, current + step)) / total, resolve: resolver)
    }


    /// Read when VoiceOver (or a UI test) asks: the speed shows only while playing or when it isn't 1×.
    override var accessibilityElements: [Any]? {
        get { accessibilityParts }
        set {}
    }

    var accessibilityParts: [Any] {
        var parts: [Any] = [playButton, wave]
        if !speedButton.isHidden { parts.append(speedButton) }
        if !retryButton.isHidden { parts.append(contentsOf: [failLabel, retryButton] as [Any]) }
        parts.append(wordsView)
        if !moreButton.isHidden { parts.append(moreButton) }
        return parts
    }
}

/// Lets the waveform's scrub begin only for a mostly horizontal drag (a vertical one scrolls the chat). A delegate of
/// that one recognizer: UIView's own `gestureRecognizerShouldBegin` is asked about every recognizer whose touch starts
/// in the view, the table's pan included, and must not be overridden for this.
private final class ScrubPanGate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        guard let pan = gr as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: pan.view)
        return abs(v.x) > abs(v.y) * 1.2
    }
}

/// The bars: played ones in the bubble's text colour, the rest at `restAlpha`. The played colour covers the bars up to
/// `progress` (a bubble: it sweeps through a bar as it plays) or the first `played` whole bars (review).
final class MemoWaveView: UIView {
    var barCount = 24 { didSet { if barCount != oldValue { rebuild() } } }
    var heights: [Double] = [] { didSet { if heights != oldValue { rebuild() } } }
    var played = 0 { didSet { if played != oldValue { progress = nil; updateMask() } } }
    /// 0…1 of the width played; nil uses `played`.
    var progress: Double? { didSet { if progress != oldValue { updateMask() } } }
    var onAdjust: ((Double) -> Void)?
    var barColor: UIColor = ChatPalette.meText { didSet { rebuild() } }
    /// The played bars' colour (review: the tint); `barColor` when nil.
    var playedColor: UIColor? { didSet { rebuild() } }
    var restAlpha: CGFloat = 0.55 { didSet { if restAlpha != oldValue { rebuild() } } }
    var barWidth: CGFloat = 2 { didSet { if barWidth != oldValue { rebuild() } } }
    var barGap: CGFloat = 2 { didSet { if barGap != oldValue { rebuild() } } }
    /// A bar's height from its 0…1 value.
    var barHeightRange: ClosedRange<CGFloat> = 3...22 { didSet { if barHeightRange != oldValue { rebuild() } } }
    private let rest = CAShapeLayer()
    private let done = CAShapeLayer()
    private let doneMask = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(rest)
        layer.addSublayer(done)
        doneMask.backgroundColor = UIColor.black.cgColor
        done.mask = doneMask
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Voice memo position"
        accessibilityIdentifier = "memo.wave"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MemoWaveView, _) in view.rebuild() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuild()
    }

    private var pitch: CGFloat { barWidth + barGap }

    private func path() -> CGPath {
        let path = UIBezierPath()
        let h = bounds.height
        // Never past the view's own width (verify round 1: 40 bars drawn into a 62 pt frame ran under the time and Send).
        let fits = Int((bounds.width + barGap + 0.5) / pitch)
        let span = barHeightRange.upperBound - barHeightRange.lowerBound
        for i in 0..<min(barCount, fits) {
            let value = i < heights.count ? heights[i] : 0.18
            let barH = min(h, (barHeightRange.lowerBound + CGFloat(value) * span).rounded())
            path.append(UIBezierPath(roundedRect: CGRect(x: CGFloat(i) * pitch, y: ((h - barH) / 2).rounded(), width: barWidth, height: barH),
                                     cornerRadius: barWidth / 2))
        }
        return path.cgPath
    }

    private func rebuild() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rest.frame = bounds
        done.frame = bounds
        rest.fillColor = barColor.withAlphaComponent(restAlpha).resolvedColor(with: traitCollection).cgColor
        done.fillColor = (playedColor ?? barColor).resolvedColor(with: traitCollection).cgColor
        let bars = path()
        rest.path = bars
        done.path = bars
        CATransaction.commit()
        updateMask()
    }

    private func updateMask() {
        let x: CGFloat
        if let progress { x = CGFloat(max(0, min(1, progress))) * bounds.width } else { x = CGFloat(max(0, min(barCount, played))) * pitch }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        doneMask.frame = CGRect(x: 0, y: 0, width: min(bounds.width, x), height: bounds.height)
        CATransaction.commit()
    }

    override func accessibilityIncrement() { onAdjust?(5) }
    override func accessibilityDecrement() { onAdjust?(-5) }
}
