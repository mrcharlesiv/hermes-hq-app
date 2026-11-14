// "Talk with <Bot>" (the one-time intro) and "How Voice Works" (its info form) (docs/spec/3x-talk.md §5.3). A page
// sheet with a grabber; the system gives it its glass. Start Talking sets `hq.voice.introSeen`; Not Now, or pulling
// the sheet down, starts nothing and leaves the key unset, so the sheet is offered again on the next tap.

import UIKit

final class TalkIntroSheet: UIViewController {
    enum Form { case intro, info }

    static let seenKey = "hq.voice.introSeen"
    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    struct Row: Equatable {
        var symbol: String
        var title: String
        var body: String
    }

    /// The sheet's rows, in order.
    static func rows(_ form: Form, name: String, app: String, sendOnRelease: Bool) -> [Row] {
        var rows = [
            Row(symbol: "waveform", title: "Just talk", body: "Pause when you’re done, and \(name) answers out loud."),
            Row(symbol: "hand.raised.fill", title: "Interrupt anytime", body: "Start talking or \(DeviceWord.tap) Interrupt to cut in."),
            Row(symbol: "text.bubble", title: "It’s all in the chat", body: "What you say and what \(name) answers appear in the chat as messages."),
            // [talk-background] The conversation goes on with the app away (3x-talk-background.md); this row said "Keep
            // <app> open: the conversation stops if you lock your iPhone or switch apps". Mac stress #42: the Mac's symbol.
            Row(symbol: deviceSymbol, title: "Keeps going in the background",
                body: "Lock your \(DeviceWord.name) or switch apps and the conversation carries on. Quitting \(app) ends it."),
        ]
        guard form == .info else { return rows }
        // [mac] Stress test 2026-10-28 #27: a mouse clicks and holds (as the memo tips say).
        let hold = DeviceWord.isMac ? "Click and hold" : "Hold"
        rows.append(Row(symbol: "mic", title: "Voice memos", body: sendOnRelease
            ? "\(hold) the mic and talk, then let go to send. A quick \(DeviceWord.tap) records hands-free; \(DeviceWord.tap) Send when you’re done."
            : "\(hold) the mic and talk; letting go stops it, so you can play it back before you send. A quick \(DeviceWord.tap) records hands-free."))
        // "The conversation", not "voice": beside Voice memos, "voice" read as either (memos never pause).
        rows.append(Row(symbol: "pause.circle", title: "If a conversation pauses",
                        body: "A call, Siri or 2 minutes of silence pauses the conversation. \(DeviceWord.Tap) Resume in the message field; Copy Details shows what went wrong."))
        return rows
    }

    /// The device beside "Keeps going in the background": the one DeviceWord names, never an iPhone on a Mac.
    static var deviceSymbol: String {
        if DeviceWord.isMac { return "laptopcomputer" }
        return DeviceWord.name == "iPad" ? "ipad" : "iphone"
    }

    private let form: Form
    private let name: String
    private var onStart: (() -> Void)?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    /// [glass-design] The hairlines between the rows (only on the glass card) and the stack's side inset.
    private var rules: [UIView] = []
    private var sideInset: CGFloat = 24

    /// Presents the sheet. `onStart` runs after Start Talking has dismissed it. Returns false when nothing could be
    /// presented (no window, another presentation in flight): the caller starts anyway and the key stays unset.
    @discardableResult
    static func present(_ form: Form, name: String, from presenter: UIViewController, onStart: (() -> Void)? = nil) -> Bool {
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return false }
        let sheet = TalkIntroSheet(form: form, name: name, onStart: onStart)
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.hqGlassTrait()   // [glass-design] the rows go on a card while it sits on glass
        presenter.present(sheet, animated: true)
        return true
    }

    init(form: Form, name: String, onStart: (() -> Void)?) {
        self.form = form
        self.name = name
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = form == .intro ? "talk.intro" : "talk.info"
        // [Mac UI check 2026-11-13] A1: the sheet had no page colour of its own, so the dark Desktop Look's light words sat
        // on a blank pale sheet; the sheets' page (clear on Liquid Glass, as before), and the title in the theme's ink.
        view.backgroundColor = HQPalette.sheetPage
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let title = UILabel()
        title.text = form == .intro ? "Talk with \(name)" : "How Voice Works"
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: HQFont.system(ofSize: 22, weight: .bold))
        title.textColor = HQPalette.label
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        title.accessibilityTraits = .header
        title.accessibilityIdentifier = "talk.intro.title"
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(12, after: title)

        // [glass-design] The rows on one solid card while the sheet sits on glass (the chat's bubbles smeared through
        // the words), with a hairline between them as grouped rows have; off the glass they stand on the page as before.
        let rows = Self.rows(form, name: name, app: MemoNotice.appName, sendOnRelease: MemoController.shared.sendOnRelease)
        let card = SheetGlassCard()
        card.verticalPadding = 4
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = UIView()
                rule.backgroundColor = HQPalette.separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                let line = UIView()
                line.addSubview(rule)
                NSLayoutConstraint.activate([
                    rule.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 36 + 14),
                    rule.trailingAnchor.constraint(equalTo: line.trailingAnchor),
                    rule.topAnchor.constraint(equalTo: line.topAnchor),
                    rule.bottomAnchor.constraint(equalTo: line.bottomAnchor),
                    rule.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
                ])
                rules.append(line)
                card.content.addArrangedSubview(line)
            }
            card.content.addArrangedSubview(rowView(row))
        }
        stack.addArrangedSubview(card)
        stack.setCustomSpacing(16, after: card)

        if form == .intro {
            var start = UIButton.Configuration.borderedProminent()
            start.title = "Start Talking"
            start.cornerStyle = .capsule
            start.buttonSize = .large
            start.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = HQFont.preferred(.headline)
                return outgoing
            }
            let startButton = UIButton(configuration: start, primaryAction: UIAction { [weak self] _ in self?.start() })
            startButton.accessibilityIdentifier = "talk.intro.start"
            startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            stack.addArrangedSubview(startButton)
            stack.setCustomSpacing(4, after: startButton)
            var later = UIButton.Configuration.plain()
            later.title = "Not Now"
            let laterButton = UIButton(configuration: later, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
            laterButton.accessibilityIdentifier = "talk.intro.not-now"
            laterButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(laterButton)
        } else {
            var done = UIButton.Configuration.borderedProminent()
            done.title = "Done"
            done.cornerStyle = .capsule
            done.buttonSize = .large
            let doneButton = UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
            doneButton.accessibilityIdentifier = "talk.intro.done"
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            stack.addArrangedSubview(doneButton)
        }

        let leading = stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24)
        let trailing = scroll.frameLayoutGuide.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 24)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            leading, trailing,
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
        ])
        // [glass-design] On the glass the card takes the grouped cards' edges (the view's margins, as Chat Info's rows),
        // the words inside it; off it, the page's 24 pt as before. The fitted height follows.
        card.onGlassChange = { [weak self] glass in
            guard let self else { return }
            let side = glass ? max(16, view.directionalLayoutMargins.leading) : 24
            leading.constant = side
            trailing.constant = side
            for rule in rules { rule.isHidden = !glass }
            sideInset = side
            sheetPresentationController?.invalidateDetents()
        }
        configureSheet()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (sheet: TalkIntroSheet, _) in sheet.configureSheet() }
    }

    /// One detent that fits the content, and large; only large at accessibility sizes, where the content scrolls.
    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            sheet.detents = [.large()]
            return
        }
        let fit = UISheetPresentationController.Detent.custom(identifier: .init("talk.intro.fit")) { [weak self] context in
            guard let self else { return nil }
            let whole = self.view.bounds.width > 0 ? self.view.bounds.width : (self.presentingViewController?.view.bounds.width ?? 390)
            let width = max(200, whole - 2 * self.sideInset)
            let height = self.stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            return min(context.maximumDetentValue, height + 28 + 12)
        }
        sheet.detents = [fit, .large()]
    }

    private func rowView(_ row: Row) -> UIView {
        let glyph = UIImageView(image: UIImage(systemName: row.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)))
        glyph.tintColor = ChatPalette.tint   // built before the sheet is on screen: its own tint is still iOS's blue
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let title = UILabel()
        title.text = row.title
        title.font = HQFont.preferred(.headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = ChatPalette.label
        title.numberOfLines = 0
        let body = UILabel()
        body.text = row.body
        body.font = HQFont.preferred(.subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ChatPalette.label2
        body.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, body])
        text.axis = .vertical
        text.spacing = 2
        let line = UIStackView(arrangedSubviews: [glyph, text])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 14
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        // One VoiceOver element reading "title. body".
        line.isAccessibilityElement = true
        line.accessibilityLabel = "\(row.title). \(row.body)"
        return line
    }

    private func start() {
        Self.seen = true
        let run = onStart
        onStart = nil
        dismiss(animated: true) { run?() }
    }
}
