import UIKit

// The phone's own fields for typing into the page while the person holds the browser (the web app's hidden-field trick,
// natively): one per kind of page field. The password one is a secure field with `.password` content type, so iOS
// offers password AutoFill (Passwords, 1Password…) in its QuickType bar; the username one `.username`; the code one
// `.oneTimeCode` (codes from Messages and Mail). Whatever lands in a field (typed, dictated, pasted, AutoFilled) goes to
// the page as `text` and the field empties again; Delete on the empty field, Return, Tab, Escape and the arrows go as
// keys. Nothing typed is stored or logged.

final class BrowserKeyField: UITextField, UITextFieldDelegate {
    let slot: BrowserKeyboardSlot
    var onText: ((String) -> Void)?
    var onKey: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init(slot: BrowserKeyboardSlot, name: String) {
        self.slot = slot
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        delegate = self
        alpha = 0.02
        tintColor = .clear
        textColor = .clear
        font = HQFont.scaled(16, like: .callout, cap: 24)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        returnKeyType = .default
        switch slot {
        case .text:
            accessibilityLabel = "Type in \(name)’s browser"
            textContentType = nil
        case .username:
            accessibilityLabel = "Sign-in name for \(name)’s page"
            textContentType = .username
        case .password:
            accessibilityLabel = "Password for \(name)’s page"
            textContentType = .password
            isSecureTextEntry = true
        case .code:
            accessibilityLabel = "Code for \(name)’s page"
            textContentType = .oneTimeCode
            keyboardType = .asciiCapable
        }
        accessibilityIdentifier = "browser.keyboard.\(slot.rawValue)"
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The keyboard the page's field wants (the text slot only; sign-in slots keep theirs).
    func use(_ kind: BrowserKeyboardKind) {
        guard slot == .text || slot == .username else { return }
        let type: UIKeyboardType = switch kind {
        case .text: .default
        case .email: .emailAddress
        case .tel: .phonePad
        case .url: .URL
        case .decimal: .decimalPad
        case .search: .webSearch
        }
        if keyboardType != type {
            keyboardType = type
            if isFirstResponder { reloadInputViews() }
        }
    }

    @objc private func changed() {
        guard markedTextRange == nil else { return }       // a composition (kana, pinyin) waits until it commits
        let value = text ?? ""
        guard !value.isEmpty else { return }
        text = ""
        // AutoFill can fill a sign-in pair at once: only the field being typed in speaks for the page.
        guard isFirstResponder else { return }
        let line = value.replacingOccurrences(of: "\n", with: "")
        if !line.isEmpty { onText?(line) }
        if value.contains("\n") { onKey?("Enter") }
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty { onKey?("Backspace") } else { super.deleteBackward() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onKey?("Enter")
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onFocusChange?(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { onFocusChange?(false) }

    // Hardware keyboards: the keys a page needs.
    override var keyCommands: [UIKeyCommand]? {
        let keys: [(String, String)] = [(UIKeyCommand.inputLeftArrow, "ArrowLeft"), (UIKeyCommand.inputRightArrow, "ArrowRight"),
                                        (UIKeyCommand.inputUpArrow, "ArrowUp"), (UIKeyCommand.inputDownArrow, "ArrowDown"),
                                        (UIKeyCommand.inputEscape, "Escape"), ("\t", "Tab")]
        return keys.map { input, _ in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(hardwareKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func hardwareKey(_ command: UIKeyCommand) {
        let names = [UIKeyCommand.inputLeftArrow: "ArrowLeft", UIKeyCommand.inputRightArrow: "ArrowRight",
                     UIKeyCommand.inputUpArrow: "ArrowUp", UIKeyCommand.inputDownArrow: "ArrowDown",
                     UIKeyCommand.inputEscape: "Escape", "\t": "Tab"]
        if let input = command.input, let name = names[input] { onKey?(name) }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] On the Mac the key commands above never match in a text field: Tab and the arrows reach `pressesBegan`
    /// (where the field would move focus or an empty caret), and Escape doesn't reach the field at all (the Mac's text
    /// system takes it and asks the field nothing). The menu bar's Stop or Close (Escape) comes first, though, and
    /// goes to the first responder: while this field has the keyboard, that command is the page's Escape.
    private static let macKeys: [UIKeyboardHIDUsage: String] = [
        .keyboardLeftArrow: "ArrowLeft", .keyboardRightArrow: "ArrowRight", .keyboardUpArrow: "ArrowUp",
        .keyboardDownArrow: "ArrowDown", .keyboardTab: "Tab",
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, key.modifierFlags.isDisjoint(with: [.shift, .control, .alternate, .command]),
           let name = Self.macKeys[key.keyCode] {
            onKey?(name)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    @objc func hqEscape(_ sender: Any?) { onKey?("Escape") }
    #endif

    // Never a caret, a selection menu or a magnifier: the field is a pipe to the page.
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        #if targetEnvironment(macCatalyst)
        if action == KeyCommands.escape { return true }
        #endif
        return action == #selector(paste(_:)) ? super.canPerformAction(action, withSender: sender) : false
    }
}
