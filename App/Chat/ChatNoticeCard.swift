// [transcript] The two cards docked above the composer (docs/spec/3x-transcript.md §6.2, §6.3): a problem with the chat
// itself ("This chat’s model couldn’t start" · Choose a Model) and a send that did not go ("Couldn’t Send" · Try
// Again). Native glass like the memo notice card; each stays until it is dealt with or closed.

import UIKit

/// What the chat screen reads the two cards from (`LiveChatSession`).
protocol ChatComposerNotices: AnyObject {
    var sessionProblem: SessionProblem? { get }
    var sendFailure: SendFailure? { get }
    /// [owner-wait] A send waiting for another Hermes process to let go of the chat.
    var ownerWaitNotice: OwnerWait? { get }
    /// The wait itself (stays when the card's ✕ hid the card): the model hasn't been asked yet.
    var ownerWaitKind: OwnerWait? { get }
    func dismissOwnerWait()
    func cancelOwnerWait()
    func dismissSessionProblem()
    func dismissSendFailure()
    func retryAfterProblem()
}

extension LiveChatSession: ChatComposerNotices {}

/// How long a turn took (§6.6), by the id of the reply it ended in.
protocol ChatTurnMarks: AnyObject {
    func turnSeconds(_ messageId: String) -> Double?
}

extension LiveChatSession: ChatTurnMarks {}

/// The read of earlier messages failed and waits for "Try Again" (§4.2).
protocol ChatOlderPaging: AnyObject {
    var olderFailed: Bool { get }
    func retryOlder()
}

extension LiveChatSession: ChatOlderPaging {}

/// [transcript] §4.2 (the web's `EarlierButton`): what the top of the loaded chat says about the messages before it.
/// "Show earlier messages" when nothing is loading (paging starts by itself six screens early, so this is what
/// VoiceOver and Switch Control users act on), "Loading earlier messages…" with a spinner, or the failure with
/// "Try Again". DECISION: a glass capsule under the status line, shown only while the reader is at the top of what is
/// loaded, rather than a row in the transcript: its three states then never move a message.
final class ChatEarlierPill: UIView {
    enum State: Equatable { case hidden, idle, loading, failed }

    static let idleText = "Show earlier messages"
    static let loadingText = "Loading earlier messages…"
    static let failedText = "Couldn’t load earlier messages from \(HostWord.phrase)."
    /// The phone has no connection: nothing failed on the computer (they load by themselves once it is back).
    static let failedOfflineText = "Couldn’t load earlier messages while you’re offline."

    var onLoad: (() -> Void)?
    private(set) var state: State = .hidden

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(18))
        return view
    }()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let button = UIButton(type: .system)
    /// The spinner and the words. Hidden with "Show earlier messages" alone: left in, its 44 pt floor stood empty
    /// above the button and doubled the pill's height (owner screenshot, 2026-10-28).
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "chat.earlier"
        alpha = 0
        isHidden = true
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = ChatPalette.label2
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityIdentifier = "chat.earlier.text"
        button.tintColor = ChatPalette.tint
        button.accessibilityIdentifier = "chat.earlier.action"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        spinner.hidesWhenStopped = true
        row.addArrangedSubview(spinner)
        row.addArrangedSubview(label)
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        let column = UIStackView(arrangedSubviews: [row, button])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)
        // Under required, so hiding the row (its stack's zero height) doesn't break it. 44 like the button, so tapping
        // "Show earlier messages" swaps in "Loading…" without the pill changing height.
        let rowFloor = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        rowFloor.priority = .init(999)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -2),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            rowFloor,
        ])
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ChatEarlierPill, _) in view.applyFonts() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyFonts() {
        let size = min(HQFont.preferred(.footnote, compatibleWith: traitCollection).pointSize, 22)
        label.font = HQFont.face(ofSize: size)
        button.titleLabel?.font = HQFont.system(ofSize: size + 2, weight: .semibold)
    }

    /// Whether the last failure came while the chat was offline (its words say so).
    private var failedOffline = false

    func set(_ next: State, offline: Bool = false) {
        if next == .failed, state == .failed, offline != failedOffline {
            failedOffline = offline
            label.text = offline ? Self.failedOfflineText : Self.failedText
            return
        }
        guard next != state else { return }
        let before = state
        state = next
        if next == .failed { failedOffline = offline }
        switch next {
        case .hidden: break
        case .idle:
            spinner.stopAnimating()
            label.isHidden = true
            row.isHidden = true
            button.isHidden = false
            button.setTitle(Self.idleText, for: .normal)
        case .loading:
            spinner.startAnimating()
            row.isHidden = false
            label.isHidden = false
            label.text = Self.loadingText
            label.accessibilityTraits = .updatesFrequently
            button.isHidden = true
        case .failed:
            spinner.stopAnimating()
            row.isHidden = false
            label.isHidden = false
            let words = failedOffline ? Self.failedOfflineText : Self.failedText
            label.text = words
            label.accessibilityTraits = .staticText
            button.isHidden = false
            button.setTitle("Try Again", for: .normal)
            Haptics.play(.error)   // once per failure, not per appearance
            HQAnnounce.say(words, priority: .high, coalesce: true)
        }
        // One line (the button, or the spinner and its words) is a capsule like the status line above it; the wrapped
        // failure keeps the card's corners.
        if next != .hidden { glass.cornerConfiguration = next == .failed ? .corners(radius: .fixed(18)) : .capsule() }
        let shown = next != .hidden
        if shown { isHidden = false }
        let changes = { self.alpha = shown ? 1 : 0 }
        let done: (Bool) -> Void = { _ in if self.state == .hidden { self.isHidden = true; self.spinner.stopAnimating() } }
        if window != nil, !HQMotion.reduced, before == .hidden || !shown {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: done)   // motion-ok: skipped under Reduce Motion
        } else {
            changes(); done(true)
        }
    }

    @objc private func tapped() { onLoad?() }
}

final class ChatNoticeCard: UIView {
    struct Content: Equatable {
        var title: String
        var body: String
        var primary: String
        /// What Copy puts on the pasteboard; nil hides Copy.
        var copyText: String?
        /// [owner-wait] A card that only informs (a waiting send): a grey clock, not the red mark.
        var calm = false
    }

    var onPrimary: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var content: Content?
    /// What the chat screen last put on show (nil: the card is away).
    var shownContent: Content?

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(20))
        return view
    }()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    /// The action and Copy side by side; one under the other at accessibility sizes ("Continue in New Chat" beside
    /// Copy was cut off at the largest).
    private let buttons = UIStackView()

    /// `identifier`: "chat.problem" or "chat.sendFailure"; the parts are `<identifier>.title`, `.body`, `.action`,
    /// `.copy`, `.close`.
    init(identifier: String) {
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false

        glyph.contentMode = .center
        glyph.tintColor = ChatPalette.red
        glyph.isAccessibilityElement = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.textColor = ChatPalette.label
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = identifier + ".title"
        bodyLabel.textColor = ChatPalette.label2
        bodyLabel.numberOfLines = 4
        bodyLabel.accessibilityIdentifier = identifier + ".body"

        primaryButton.tintColor = ChatPalette.tint
        primaryButton.accessibilityIdentifier = identifier + ".action"
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        copyButton.setTitle("Copy", for: .normal)
        copyButton.tintColor = ChatPalette.tint
        copyButton.accessibilityIdentifier = identifier + ".copy"
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        closeButton.tintColor = ChatPalette.label2
        closeButton.accessibilityLabel = "Close"
        closeButton.accessibilityIdentifier = identifier + ".close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [glyph, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        buttons.addArrangedSubview(primaryButton)
        buttons.addArrangedSubview(copyButton)
        buttons.addArrangedSubview(UIView())
        buttons.axis = .horizontal
        buttons.spacing = 16
        buttons.alignment = .center
        let column = UIStackView(arrangedSubviews: [header, bodyLabel, buttons])
        column.axis = .vertical
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)
        glass.contentView.addSubview(closeButton)
        let bottom = column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 12 pt above the words and 14 pt beside them (wrapping rows get 12–14 pt); the buttons' own 44 pt height
            // is the room under them.
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: 2),
            bottom,
            closeButton.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        clipsToBounds = false
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ChatNoticeCard, _) in view.applyFonts() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func scaled(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight, max: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: HQFont.system(ofSize: size, weight: weight), maximumPointSize: max,
                                                      compatibleWith: traitCollection)
    }

    private func applyFonts() {
        let title = scaled(.subheadline, 15, .semibold, max: 28)
        titleLabel.font = title
        bodyLabel.font = scaled(.footnote, 13, .regular, max: 26)
        primaryButton.titleLabel?.font = title
        copyButton.titleLabel?.font = scaled(.subheadline, 15, .regular, max: 28)
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = large ? .vertical : .horizontal
        buttons.alignment = large ? .leading : .center
        buttons.spacing = large ? 0 : 16
        for button in [primaryButton, copyButton] {
            button.titleLabel?.numberOfLines = large ? 0 : 1
            button.contentHorizontalAlignment = .leading
        }
        // The ✕ grows with the text too (its 44 pt target holds it up to 20 pt).
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(
            pointSize: scaled(.footnote, 13, .semibold, max: 20).pointSize, weight: .semibold)), for: .normal)
        glyphPointSize = title.pointSize
        applyGlyph()
    }

    private var glyphPointSize: CGFloat = 15
    private func applyGlyph() {
        let calm = content?.calm ?? false
        glyph.tintColor = calm ? ChatPalette.label2 : ChatPalette.red
        glyph.image = UIImage(systemName: calm ? "clock" : "exclamationmark.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .semibold))
    }

    func show(_ content: Content) {
        self.content = content
        titleLabel.text = content.title
        bodyLabel.text = content.body
        bodyLabel.isHidden = content.body.isEmpty
        primaryButton.setTitle(content.primary, for: .normal)
        copyButton.isHidden = content.copyText == nil
        applyGlyph()
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func closeTapped() {
        Haptics.play(.selection)   // as the transcript error card's ✕ and the reply banner's
        onClose?()
    }
    @objc private func copyTapped() {
        guard let text = content?.copyText else { return }
        UIPasteboard.general.string = text
        Haptics.play(.success)
        CopyFeedback.flash(copyButton)
    }
}

extension ChatNoticeCard.Content {
    init(_ problem: SessionProblem) {
        self.init(title: problem.title, body: problem.body,
                  primary: Self.title(problem.primary), copyText: problem.copyText)
    }

    static func title(_ primary: SessionProblem.Primary) -> String {
        switch primary {
        case .chooseModel: "Choose a Model"
        case .tryAgain: "Try Again"
        case .newChat: "Continue in New Chat"   // [locked-chat]
        }
    }

    init(_ failure: SendFailure) {
        self.init(title: SendFailure.title, body: failure.body, primary: "Try Again", copyText: failure.copyText)
    }

    init(_ wait: OwnerWait) {
        self.init(title: OwnerWait.cardTitle, body: wait.cardBody, primary: OwnerWait.cancelTitle, copyText: nil, calm: true)
    }
}
