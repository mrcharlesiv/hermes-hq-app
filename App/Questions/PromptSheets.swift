import UIKit

// Password, secret and vault sheets (spec 1x §4.5, MEM:password-request-chip, MEM:bot-owns-signin): the shared sheet
// frame (ChatSheet.wrap), AutoFill field types, a red decline under the fields, and every close — ✕, swipe down, tap
// outside — tucks into a centred glass chip that keeps the typed text. Typed values live only in these fields (Q15):
// never logged, cached or copied; cleared when the request goes (answered, withdrawn, sign-out) and dropped with the
// sheet. The account's `PromptSheetStore` keeps the sheets (PromptSheetStore.swift).

@MainActor protocol PromptSheetDelegate: AnyObject {
    /// Primary ("Send", "Unlock", …) or the red decline (value "").
    func promptSheet(_ sheet: PromptSheetController, answer value: String)
    /// ✕, swipe down, tap outside: nothing goes on the wire.
    func promptSheetTucked(_ sheet: PromptSheetController)
}

/// The words of one value prompt (copy: V:desktop/src/i18n/en.ts:5470-5511; Q10 drops the Settings footnotes). The
/// phone names the chat's bot where the desktop says "the agent", "the model" or "Hermes", and its titles and buttons
/// are in Title Case.
nonisolated struct PromptSheetCopy: Sendable, Equatable {
    enum Field: Sendable, Equatable { case secure(placeholder: String), username, password, code }
    var title: String
    var text: String
    var command: String?           // sudo: the command block (nil = none given)
    var commandMissing: String?    // sudo with no command
    var key: String? = nil         // secret: the variable it asks for, under the text in monospace
    var fields: [Field]
    var primary: String
    var decline: String
    var chip: String

    /// `botName`: the chat's bot ("Ivy needs a key"); nil says "the bot".
    static func make(_ prompt: ValuePrompt, botName: String? = nil) -> PromptSheetCopy {
        let p = prompt.params
        let named = botName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        // Mid-sentence, at the start of one, and in a title.
        let bot = named ?? "the bot", botStart = named ?? "The bot", botTitle = named ?? "Your Bot"
        func nonEmpty(_ key: String) -> String? {
            p[key]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch prompt.kind {
        case .sudo:
            let command = nonEmpty("command")
            return PromptSheetCopy(
                title: "Administrator Password",
                // [sudo-tidy] One line under the field: the command itself now leads the sheet.
                text: "Your password is sent to \(bot) to run this, and kept for this session.",
                command: command,
                commandMissing: command == nil ? "\(botStart) didn’t say which command. Choose Don’t Send if you can’t check it in the conversation." : nil,
                fields: [.secure(placeholder: "sudo password")], primary: "Send", decline: "Don’t Send", chip: "Password requested")
        case .secret:
            // The variable's name is a detail under the words, not the title (a raw "OPENWEATHER_API_KEY" read as one).
            let env = nonEmpty("env_var")
            return PromptSheetCopy(title: "\(botTitle) Needs a Key", text: nonEmpty("prompt") ?? "\(botStart) needs a key to continue.",
                                   command: nil, commandMissing: nil, key: env, fields: [.secure(placeholder: env ?? "secret value")],
                                   primary: "Send", decline: "Don’t Send", chip: env.map { "\($0) requested" } ?? "Secret requested")
        case .vaultUnlock:
            let name = nonEmpty("display_name") ?? nonEmpty("backend")
            let shown = name ?? "your password manager"
            return PromptSheetCopy(
                title: "Unlock \(name ?? "Password Manager")",
                text: "\(botStart) wants to sign into a site with a login saved in \(shown). Enter your master password to unlock it for this session — it goes straight to \(shown) on \(HostWord.phrase) and is never stored or shown to \(bot).",
                command: nil, commandMissing: nil, fields: [.secure(placeholder: "Master password")], primary: "Unlock",
                decline: "Keep Locked", chip: name.map { "Unlock \($0)" } ?? "Unlock password manager")
        case .vaultSaveLogin:
            let site = nonEmpty("site") ?? nonEmpty("origin")
            let origin = nonEmpty("origin") ?? site ?? "this site"
            if prompt.late {
                // The bot stopped waiting (timed out, Hermes restarted): Save stores it and messages the bot.
                return PromptSheetCopy(
                    title: "Save Your \(site ?? "Site") Login?",
                    text: "\(botStart) stopped waiting for this login. Save it here and \(bot) gets a message to sign in to \(origin) with it. It is encrypted on \(HostWord.phrase) and \(bot) never sees the password.",
                    command: nil, commandMissing: nil, fields: [.username, .password], primary: "Save and Tell \(named ?? "the Bot")", decline: "Don’t Save",
                    chip: site.map { "Login for \($0) still needed" } ?? "Login still needed")
            }
            return PromptSheetCopy(
                title: "Save Your \(site ?? "Site") Login?",
                text: "\(botStart) reached a sign-in page at \(origin) and has no login for it. Enter it once here; it is encrypted on \(HostWord.phrase) and filled into the page without \(bot) ever seeing the password.",
                command: nil, commandMissing: nil, fields: [.username, .password], primary: "Save and Sign In", decline: "Don’t Save",
                chip: site.map { "Save login for \($0)?" } ?? "Save login?")
        case .vaultCode:
            let site = nonEmpty("site")
            return PromptSheetCopy(
                title: "Verification Code for \(site ?? "This Site")",
                text: "\(site ?? "The site") is asking for a one-time code (text message, email or authenticator app). Enter it here and it’s typed into the page; \(bot) never sees it.",
                command: nil, commandMissing: nil, fields: [.code], primary: "Enter Code", decline: "Skip",
                chip: site.map { "Code for \($0) requested" } ?? "Code requested")
        case .approval, .clarify:
            return PromptSheetCopy(title: "", text: "", command: nil, commandMissing: nil, fields: [], primary: "", decline: "", chip: "")
        }
    }
}

final class PromptSheetController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    let prompt: ValuePrompt
    let copy: PromptSheetCopy
    weak var delegate: PromptSheetDelegate?
    /// The sheet frame this controller lives in. Weak: the frame holds the sheet, and whoever keeps the sheet (the
    /// store) keeps the frame; re-presented as the same instance after a tuck.
    private(set) weak var navigation: UINavigationController?
    private let closeItem: UIBarButtonItem
    private var fields: [UITextField] = []
    private var primaryItem: UIBarButtonItem!
    /// [sudo-tidy] The bot's name at the start of a sentence ("Ivy wants to run").
    private let botLead: String
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var sending = false
    /// Don't Send / Keep Locked / Don't Save / Skip: dimmed with the primary while an answer is on its way.
    private weak var declineButton: UIButton?

    /// A sheet in its frame (`ChatSheet.wrap`). The caller keeps the navigation controller; it holds the sheet.
    static func make(_ prompt: ValuePrompt, botName: String? = nil) -> (sheet: PromptSheetController, navigation: UINavigationController) {
        let sheet = PromptSheetController(prompt: prompt, botName: botName)
        let navigation = ChatSheet.wrap(sheet, title: sheet.copy.title)
        sheet.navigationItem.hqPlaceFormClose(sheet.closeItem)   // the frame's plain ✕ dismisses; ours tucks (beside the primary, so leading)
        sheet.navigation = navigation
        navigation.presentationController?.delegate = sheet
        return (sheet, navigation)
    }

    init(prompt: ValuePrompt, botName: String? = nil) {
        self.prompt = prompt
        self.copy = PromptSheetCopy.make(prompt, botName: botName)
        let named = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        botLead = named.isEmpty ? "The bot" : named
        // Every close tucks (MEM:password-request-chip, build 85): the ✕ too.
        let close = UIBarButtonItem.hqClose(action: nil)   // [mac] #55: Done on the Mac
        close.accessibilityIdentifier = "sheet.close"
        closeItem = close
        super.init(nibName: nil, bundle: nil)
        close.primaryAction = UIAction(title: close.title ?? "") { [weak self] _ in self?.tuck() }   // keeps the Mac's word
        navigationItem.leftBarButtonItem = close
        // A long title ("Save your Example Shop login?") wraps to two lines instead of losing the site's name; verify
        // round 3: at the largest text sizes it also shrinks until every word fits whole (a key name broke mid-word as
        // "OPENWEATHER_API_K / EY", a site name was cut).
        let title = SheetTitleLabel()
        title.text = copy.title
        title.textAlignment = .center
        title.accessibilityTraits = .header
        navigationItem.titleView = title
        primaryItem = UIBarButtonItem(title: copy.primary, style: .prominent, target: self, action: #selector(primaryTapped))
        primaryItem.accessibilityIdentifier = "prompt.primary"
        // [sudo-tidy] The sudo sheet's Send is in the sheet, beside Don't Send; the others keep theirs in the bar.
        if !paired { navigationItem.rightBarButtonItem = primaryItem }
    }

    /// [sudo-tidy] Owner 2026-11-10 (design pick 13), the Administrator Password sheet: the command leads under
    /// "<Bot> wants to run", then the password, one line saying where it goes, and Don't Send and Send as a pair under
    /// that (Send was in the bar's corner and Don't Send floated mid-sheet).
    private var paired: Bool { prompt.kind == .sudo }
    private weak var pairedPrimary: UIButton?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage   // [glass-design] on Liquid Glass at half height, the words on cards
        view.accessibilityIdentifier = "prompt.sheet.\(prompt.kind.rawValue)"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        // [glass-design] The explanation, with the missing-command line or the key under it, is one card on the glass
        // (a paragraph never stands on the blurred chat); off the glass the words sit on the page as before.
        let words = SheetGlassCard(spacing: 12)
        words.verticalPadding = 14
        let text = label(copy.text, style: .body, color: HQPalette.label)
        text.accessibilityIdentifier = "prompt.text"
        words.content.addArrangedSubview(text)
        if copy.command == nil, let missing = copy.commandMissing {
            words.content.addArrangedSubview(label(missing, style: .footnote, color: HQPalette.label2))
        }
        if let key = copy.key {
            let line = label(key, style: .footnote, color: HQPalette.label2)
            line.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13))
            line.accessibilityIdentifier = "prompt.key"
            words.content.addArrangedSubview(line)
        }
        // [sudo-tidy] With the command to lead, the words follow the field as one quiet line.
        let wordsLast = paired && copy.command != nil
        if !wordsLast { stack.addArrangedSubview(words) }
        if let command = copy.command {
            let heading = label(paired ? "\(botLead) wants to run" : "Command", style: .footnote, color: HQPalette.label2)
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(6, after: heading)
            let block = PromptCommandBlock(command: command)
            block.onShowAll = { [weak self] in self?.showWholeCommand() }
            stack.addArrangedSubview(block)
        }
        let group = UIStackView()
        group.axis = .vertical
        group.spacing = 0
        group.backgroundColor = HQPalette.sheetCard   // [glass-design] the fields are frosted like the cards
        group.layer.cornerRadius = GlassSheetKit.designed ? GlassSheetKit.cardRadius : 12
        group.layer.cornerCurve = .continuous
        group.hqGlassEdge()   // [glass-design] its thin edge on the glass
        group.clipsToBounds = true
        for (i, kind) in copy.fields.enumerated() {
            if i > 0 {
                let line = UIView()
                line.backgroundColor = .separator
                line.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
                group.addArrangedSubview(line)
            }
            let field = makeField(kind)
            field.tag = i
            fields.append(field)
            group.addArrangedSubview(field)
        }
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last ?? words)
        stack.addArrangedSubview(group)
        if wordsLast {
            let note = label(copy.text, style: .footnote, color: HQPalette.label2)
            note.accessibilityIdentifier = "prompt.text"
            let row = UIStackView(arrangedSubviews: [note])
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            stack.setCustomSpacing(8, after: group)
            stack.addArrangedSubview(row)
        }
        // [glass-design] The red decline as the sheets' solid action (the plain red word read 3.5:1 on the glass); the
        // Desktop Look keeps its plain red word. [mac] The Mac's push button at its own size, centred: stretched across
        // the sheet and 44 pt tall it read as a bar, not a button (stress test 2026-10-31).
        var decline = UIButton.Configuration.hqSheetAction(destructive: true)
        decline.title = copy.decline
        let declineButton = UIButton(configuration: decline, primaryAction: UIAction { [weak self] _ in self?.send("") })
        declineButton.accessibilityIdentifier = "prompt.decline"
        self.declineButton = declineButton
        if !DeviceWord.isMac { declineButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true }
        let declineRow = UIStackView(arrangedSubviews: [declineButton])
        if paired {
            var send = UIButton.Configuration.hqSheetProminent()
            send.title = copy.primary
            let sendButton = UIButton(configuration: send, primaryAction: UIAction { [weak self] _ in self?.primaryTapped() })
            sendButton.accessibilityIdentifier = "prompt.primary"
            if !DeviceWord.isMac { sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true }
            pairedPrimary = sendButton
            declineRow.addArrangedSubview(sendButton)
            declineRow.axis = .horizontal
            declineRow.spacing = 10
            declineRow.distribution = DeviceWord.isMac ? .fill : .fillEqually
            if DeviceWord.isMac { declineRow.insertArrangedSubview(UIView(), at: 0) }
        } else {
            declineRow.axis = .vertical
            declineRow.alignment = GlassSheetKit.designed || DeviceWord.isMac ? .center : .fill
        }
        stack.setCustomSpacing(GlassSheetKit.designed ? 16 : 8, after: stack.arrangedSubviews.last ?? group)
        stack.addArrangedSubview(declineRow)
        updatePrimary()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if fields.allSatisfy({ !$0.isFirstResponder }) { (fields.first { ($0.text ?? "").isEmpty } ?? fields.first)?.becomeFirstResponder() }
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = HQFont.preferred(style)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = color
        l.numberOfLines = 0
        return l
    }

    private func makeField(_ kind: PromptSheetCopy.Field) -> UITextField {
        let f = InsetTextField()
        f.font = HQFont.preferred(.body)
        f.adjustsFontForContentSizeCategory = true
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.spellCheckingType = .no
        f.delegate = self
        f.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        f.addTarget(self, action: #selector(changed), for: .editingChanged)
        switch kind {
        case .secure(let placeholder):
            f.placeholder = placeholder
            f.isSecureTextEntry = true
            f.textContentType = .password
            f.accessibilityIdentifier = "prompt.secure"
        case .username:
            f.placeholder = "you@example.com"
            f.textContentType = .username
            f.keyboardType = .emailAddress
            f.accessibilityLabel = "Email or username"
            f.accessibilityIdentifier = "prompt.username"
        case .password:
            f.placeholder = "Password"
            f.isSecureTextEntry = true
            f.textContentType = .password
            f.accessibilityIdentifier = "prompt.password"
        case .code:
            f.placeholder = "123 456"
            f.textContentType = .oneTimeCode
            f.keyboardType = .numberPad
            f.addNumberPadDone()   // [diagnostics] the number pad has no Return key
            f.accessibilityLabel = "Code"
            f.accessibilityIdentifier = "prompt.code"
        }
        // [glass-design] The card's faintest words, as the New Prompt fields: the system placeholder grey read 1.7:1
        // on the card (label2 on the glass, the Desktop Look's label3 there, a gain off the glass too).
        if let words = f.placeholder {
            f.attributedPlaceholder = NSAttributedString(string: words, attributes: [.foregroundColor: HQPalette.cardNote])
        }
        return f
    }

    /// The value the primary sends, or nil while it isn't valid (Q9: never an empty sudo password from Send).
    var value: String? {
        let texts = fields.map { $0.text ?? "" }
        switch prompt.kind {
        case .vaultSaveLogin:
            let identifier = texts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password = texts.count > 1 ? texts[1] : ""
            guard !identifier.isEmpty, !password.isEmpty else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(["identifier": identifier, "password": password]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        case .vaultCode:
            let code = (texts.first ?? "").filter { !$0.isWhitespace && $0 != "-" }
            return code.isEmpty ? nil : code
        default:
            let text = texts.first ?? ""
            return text.isEmpty ? nil : text
        }
    }

    @objc private func changed() { updatePrimary() }

    private func updatePrimary() {
        primaryItem.setProminentEnabled(value != nil && !sending)
        pairedPrimary?.isEnabled = value != nil && !sending
        declineButton?.isEnabled = !sending   // its taps are ignored until the send ends, so it doesn't look live
    }

    @objc private func primaryTapped() {
        guard let value else { return }
        send(value)
    }

    private func send(_ value: String) {
        guard !sending else { return }
        delegate?.promptSheet(self, answer: value)
    }

    /// The answer is on its way (or failed: `false` lets the user try again).
    func setSending(_ on: Bool) {
        sending = on
        updatePrimary()
    }

    /// The request went (answered, withdrawn, signed out): the typed text goes (Q15, R6).
    func clear() {
        guard isViewLoaded else { return }
        fields.forEach { $0.text = nil }
        updatePrimary()
    }

    func tuck() {
        view.endEditing(true)
        (navigationController ?? navigation)?.dismiss(animated: true)
        delegate?.promptSheetTucked(self)
    }

    /// Show All under a long sudo command: the whole command in the shared blocks sheet, over this one.
    private func showWholeCommand() {
        guard let command = copy.command else { return }
        present(PromptCommandBlock.wholeCommandSheet(command), animated: true)
    }

    #if DEBUG
    /// Tests: the typed text, field by field.
    var debugFieldTexts: [String] { fields.map { $0.text ?? "" } }
    func debugType(_ texts: [String]) {
        loadViewIfNeeded()
        for (field, text) in zip(fields, texts) { field.text = text }
        updatePrimary()
    }
    var debugSending: Bool { sending }
    #endif

    // MARK: UITextFieldDelegate: Return moves on, the last field sends when valid.

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.tag + 1 < fields.count {
            fields[textField.tag + 1].becomeFirstResponder()
        } else if let value {
            send(value)
        }
        return false
    }

    // MARK: UIAdaptivePresentationControllerDelegate: a swipe down or a tap outside tucks.

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        delegate?.promptSheetTucked(self)
    }
}

/// The sudo sheet's command (§4.5): monospaced Footnote on the elevated cell colour, copyable, at most 8 lines. A
/// longer one ends in "…" with Show All under it, which opens the whole command (only the bounded head is ever laid
/// out here: a command can run to tens of KB).
final class PromptCommandBlock: UIView {
    static let maxLines = 8
    var onShowAll: (() -> Void)?
    private let body = UITextView(usingTextLayoutManager: false)
    private let showAll = UIButton(type: .system)
    private let text: NSAttributedString
    private let font: UIFont
    private let preCut: Bool

    init(command: String) {
        let (head, cut) = PromptLayout.bounded(command, maxLines: Self.maxLines)
        preCut = cut
        font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        text = NSAttributedString(string: head, attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
        super.init(frame: .zero)
        let card = UIView()
        card.backgroundColor = HQPalette.sheetCard   // [glass-design] frosted on a glass sheet, solid off it
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.hqGlassEdge()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        body.isEditable = false
        body.isScrollEnabled = false
        body.backgroundColor = .clear
        body.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        body.textContainer.lineFragmentPadding = 0
        body.textContainer.maximumNumberOfLines = Self.maxLines
        body.textContainer.lineBreakMode = .byTruncatingTail
        body.attributedText = text
        body.accessibilityIdentifier = "prompt.command"
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        var config = UIButton.Configuration.plain()
        config.title = "Show All"
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = HQFont.preferred(.footnote); return a
        }
        if GlassSheetKit.designed {   // [glass-design] the sheets' solid action, not a link on the glass
            config = UIButton.Configuration.hqSheetAction()
            config.title = "Show All"
        }
        showAll.configuration = config
        showAll.accessibilityIdentifier = "prompt.command.showAll"
        showAll.isHidden = !cut
        showAll.addAction(UIAction { [weak self] _ in self?.onShowAll?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [card, showAll])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = GlassSheetKit.designed ? 8 : 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            showAll.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// More than 8 laid-out lines (at this width), or more than the bounded head: Show All.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = body.bounds.width - body.textContainerInset.left - body.textContainerInset.right
        guard width > 0 else { return }
        let height = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        let long = preCut || Int((height / max(1, font.lineHeight)).rounded(.up)) > Self.maxLines
        if showAll.isHidden == long { showAll.isHidden = !long }
    }

    #if DEBUG
    var debugShowsAll: Bool { !showAll.isHidden }
    var debugText: String { text.string }
    #endif

    /// The whole command, in the shared blocks sheet (20,000 characters at most, as the step sheet pages it).
    static func wholeCommandSheet(_ command: String) -> UIViewController {
        var text = command
        if text.utf16.count > 20_000 { text = String(text.prefix(20_000)) + "\n…" }
        return ChatSheet.wrap(ChatBlocksViewController(heading: nil, blocks: [.init(label: "Command", text: text)]), title: "Command")
    }
}

private final class InsetTextField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 16, dy: 0) }
}

// MARK: - The chip

/// A tucked prompt waits here: a capsule of untinted interactive glass, centred above the composer, max 256 wide
/// (prompt-tuck.tsx:59-89; picture W:artifacts/password-chip/chip-over-composer.png). Tap re-presents the sheet.
final class PromptChipView: UIView {
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let icon = UIImageView()
    private let label = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "prompt.chip"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Small Subheadline (12 pt at the default size), so it grows with the words beside it.
        icon.image = UIImage(systemName: "lock.fill")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        icon.tintColor = ChatPalette.label
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = HQFont.preferred(.subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ChatPalette.label
        label.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 6
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            row.topAnchor.constraint(greaterThanOrEqualTo: glass.contentView.topAnchor, constant: 8),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ text: String) {
        label.text = text
        accessibilityLabel = "\(text). Opens the request."
    }

    var text: String? { label.text }

    @objc private func tapped() { onTap?() }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }
}

/// A sheet's two-line title: at most two lines, every word whole. The text shrinks (to 60 %) until its widest word fits
/// a line and the whole title fits two, at the width the bar gives it; past that it truncates. A one-word title stays on
/// one line.
final class SheetTitleLabel: UILabel {
    private var fittedWidth: CGFloat = -1
    private var fittedText: String?
    private var fittedCategory: UIContentSizeCategory?

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 2
        lineBreakMode = .byTruncatingTail
        font = Self.baseFont(for: traitCollection)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: SheetTitleLabel, _: UITraitCollection) in
            label.font = Self.baseFont(for: label.traitCollection)
            label.fittedWidth = -1
            label.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func baseFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .headline).scaledFont(for: HQFont.system(ofSize: 17, weight: .semibold), maximumPointSize: 22,
                                                          compatibleWith: traits)
    }

    override var text: String? {
        didSet { numberOfLines = (text ?? "").contains(" ") ? 2 : 1; fittedWidth = -1; fittedText = nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    private func fit() {
        let category = traitCollection.preferredContentSizeCategory
        guard bounds.width > 1, let text, !text.isEmpty else { return }
        if fittedText != text || fittedCategory != category { fittedWidth = -1 }
        // The widest the bar offered: a smaller frame afterwards is the bar following this label's own shrink (fitting
        // to it again would spiral down to the floor).
        guard bounds.width > fittedWidth + 0.5 else { return }
        let width = bounds.width
        fittedWidth = width
        fittedText = text
        fittedCategory = category
        let base = Self.baseFont(for: traitCollection)
        let floor = max(12, base.pointSize * 0.6)
        var size = base.pointSize
        while size > floor, !Self.fits(text, font: base.withSize(size), width: width, lines: numberOfLines) { size -= 0.5 }
        let next = base.withSize(max(size, floor))
        if font.pointSize != next.pointSize { font = next }
    }

    /// Every word fits a line and the text fits `lines` lines, wrapped at words.
    static func fits(_ text: String, font: UIFont, width: CGFloat, lines: Int) -> Bool {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = text.split(separator: " ").map { ceil(($0 as NSString).size(withAttributes: attributes).width) }.max() ?? 0
        guard widest <= width else { return false }
        let height = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: attributes, context: nil).height
        return ceil(height) <= ceil(font.lineHeight * CGFloat(lines)) + 1
    }
}
