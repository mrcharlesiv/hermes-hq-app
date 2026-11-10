import UIKit

#if !targetEnvironment(macCatalyst)
/// The hidden field that turns the iOS keyboard and a hardware keyboard into key events for the bot's screen
/// (docs/spec/3x-screen.md §5.6; the pattern of `BrowserKeyField`). It holds no text: every commit is handed on and
/// the field emptied. Nothing typed is logged.
final class ScreenKeyField: UITextField, UITextFieldDelegate {
    /// Text the keyboard committed (a composition is delivered once, when it commits).
    var onText: ((String) -> Void)?
    /// A named key, with the hardware modifiers held with it.
    var onKey: ((ScreenKeys.Named, Set<ScreenKeys.Modifier>) -> Void)?
    /// A hardware key pressed with Control, Option or Command.
    var onChord: ((String, Set<ScreenKeys.Modifier>) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.02
        tintColor = .clear
        textColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        keyboardType = .default
        returnKeyType = .default
        delegate = self
        accessibilityLabel = "Type on the bot’s screen"
        accessibilityIdentifier = "screen.keyboard"
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() {
        guard let value = ScreenKeys.committed(text, composing: markedTextRange != nil) else { return }
        text = ""
        guard isFirstResponder else { return }
        onText?(value)
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty { onKey?(.backspace, []) } else { super.deleteBackward() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onKey?(.enter, [])
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onFocusChange?(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { onFocusChange?(false) }

    // MARK: Hardware keyboards

    private static let named: [(String, ScreenKeys.Named)] = [
        (UIKeyCommand.inputLeftArrow, .left), (UIKeyCommand.inputRightArrow, .right), (UIKeyCommand.inputUpArrow, .up),
        (UIKeyCommand.inputDownArrow, .down), (UIKeyCommand.inputEscape, .escape), ("\t", .tab), (UIKeyCommand.inputDelete, .delete),
        (UIKeyCommand.inputHome, .home), (UIKeyCommand.inputEnd, .end),
        (UIKeyCommand.inputPageUp, .pageUp), (UIKeyCommand.inputPageDown, .pageDown),
    ] + zip([UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
             UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12],
            ScreenKeys.Named.function).map { ($0, $1) }

    /// Every named key with every combination of the four modifiers (23 × 16, built once): ⌘⇧← selects to the start
    /// of the line, ⌥⇧→ by word, Ctrl+Shift+Tab is the previous tab. The web forwarded all held modifiers with a
    /// named key; a command registered for one modifier does not fire for two.
    private static let commands: [UIKeyCommand] = {
        let each: [UIKeyModifierFlags] = [.shift, .control, .alternate, .command]
        var out: [UIKeyCommand] = []
        for (input, _) in named {
            for bits in 0..<16 {
                var flags: UIKeyModifierFlags = []
                for (index, flag) in each.enumerated() where bits & (1 << index) != 0 { flags.insert(flag) }
                let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(hardwareKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                out.append(command)
            }
        }
        return out
    }()

    override var keyCommands: [UIKeyCommand]? { Self.commands }

    private static func mods(_ flags: UIKeyModifierFlags) -> Set<ScreenKeys.Modifier> {
        var out: Set<ScreenKeys.Modifier> = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.ctrl) }
        if flags.contains(.alternate) { out.insert(.alt) }
        if flags.contains(.command) { out.insert(.meta) }
        return out
    }

    @objc private func hardwareKey(_ command: UIKeyCommand) {
        guard let input = command.input, let key = Self.named.first(where: { $0.0 == input })?.1 else { return }
        onKey?(key, Self.mods(command.modifierFlags))
    }

    /// A hardware key with Control, Option or Command is a chord for the bot's screen, not text for this field.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passed: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { passed.insert(press); continue }
            let mods = Self.mods(key.modifierFlags)
            let character = key.charactersIgnoringModifiers
            guard !mods.isDisjoint(with: [.ctrl, .alt, .meta]), character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
                  !Self.named.contains(where: { $0.0 == character }) else { passed.insert(press); continue }
            onChord?(character.lowercased(), mods)
        }
        if !passed.isEmpty { super.pressesBegan(passed, with: event) }
    }

    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
#else
/// [mac] The Mac's stand-in for the field above, with the same callbacks. A text field there loses Control and Option
/// chords and Escape to the Mac's text system before UIKit sees them (Option-A typed "å"; Control-C and Escape did
/// nothing), and the named keys' commands never match. So on the Mac the keyboard goes to a plain view that reads each
/// press itself, as a VNC client reads a keyboard: a named key by its key code, a key with Control, Option or Command
/// as a chord, any other key as the text it types. The menu bar's shortcuts (⌘Q, ⌘W, ⌘,) still come first, and no
/// input method composes here: the bot's computer has its own. Control-Tab and Control-Shift-Tab never reach the
/// window at all (the Mac keeps them); the key bar's Ctrl, then Tab, sends them.
final class ScreenKeyField: UIView {
    var onText: ((String) -> Void)?
    var onKey: ((ScreenKeys.Named, Set<ScreenKeys.Modifier>) -> Void)?
    var onChord: ((String, Set<ScreenKeys.Modifier>) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isAccessibilityElement = true
        accessibilityLabel = "Type on the bot’s screen"
        accessibilityIdentifier = "screen.keyboard"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        stopRepeat()
        let had = isFirstResponder
        let resigned = super.resignFirstResponder()
        if had, resigned { onFocusChange?(false) }
        return resigned
    }

    private static let named: [UIKeyboardHIDUsage: ScreenKeys.Named] = [
        .keyboardLeftArrow: .left, .keyboardRightArrow: .right, .keyboardUpArrow: .up, .keyboardDownArrow: .down,
        .keyboardEscape: .escape, .keyboardTab: .tab, .keyboardDeleteForward: .delete, .keyboardDeleteOrBackspace: .backspace,
        .keyboardReturnOrEnter: .enter, .keypadEnter: .enter,
        .keyboardHome: .home, .keyboardEnd: .end, .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
        .keyboardF1: .f1, .keyboardF2: .f2, .keyboardF3: .f3, .keyboardF4: .f4, .keyboardF5: .f5, .keyboardF6: .f6,
        .keyboardF7: .f7, .keyboardF8: .f8, .keyboardF9: .f9, .keyboardF10: .f10, .keyboardF11: .f11, .keyboardF12: .f12,
    ]

    private static func mods(_ flags: UIKeyModifierFlags) -> Set<ScreenKeys.Modifier> {
        var out: Set<ScreenKeys.Modifier> = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.ctrl) }
        if flags.contains(.alternate) { out.insert(.alt) }
        if flags.contains(.command) { out.insert(.meta) }
        return out
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passed: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { passed.insert(press); continue }
            // The same key down again while held: the system repeats it itself, so this view's own repeat stops.
            let systemRepeat = held?.code == key.keyCode
            if systemRepeat { stopRepeat() }
            guard let send = action(key) else { passed.insert(press); continue }
            send()
            if !systemRepeat, Self.mods(key.modifierFlags).isDisjoint(with: [.ctrl, .alt, .meta]) || Self.named[key.keyCode] != nil {
                startRepeat(key.keyCode, send)
            }
        }
        if !passed.isEmpty { super.pressesBegan(passed, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == held?.code }) { stopRepeat() }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == held?.code }) { stopRepeat() }
        super.pressesCancelled(presses, with: event)
    }

    /// What one press sends to the bot's screen (nil: not a key it takes, such as a modifier alone).
    private func action(_ key: UIKey) -> (() -> Void)? {
        let mods = Self.mods(key.modifierFlags)
        if let named = Self.named[key.keyCode] { return { [weak self] in self?.onKey?(named, mods) } }
        if mods.isDisjoint(with: [.ctrl, .alt, .meta]) {
            let text = key.characters
            guard !text.isEmpty, text.unicodeScalars.allSatisfy(Self.printable) else { return nil }
            return { [weak self] in self?.onText?(text) }
        }
        let character = key.charactersIgnoringModifiers
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, Self.printable(scalar) else { return nil }
        return { [weak self] in self?.onChord?(character.lowercased(), mods) }
    }

    // MARK: Held keys

    /// A held key repeats as it does on the iPad (where the named keys' commands and the field repeat by themselves):
    /// after the Mac's own delay, at its own rate (Keyboard settings), until the key comes up. Chords don't repeat.
    private var held: (code: UIKeyboardHIDUsage, timer: Timer, send: () -> Void)?

    private func startRepeat(_ code: UIKeyboardHIDUsage, _ send: @escaping () -> Void) {
        stopRepeat()
        // Both settings count in 15 ms steps; unset, they are the system's defaults.
        let defaults = UserDefaults.standard
        let delay = Double(defaults.object(forKey: "InitialKeyRepeat") as? Int ?? 25) * 0.015
        let rate = max(Double(defaults.object(forKey: "KeyRepeat") as? Int ?? 6) * 0.015, 0.015)
        // A key-up lost to another app (the window gave up the keyboard mid-hold) ends the repeat too.
        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isFirstResponder, self.window?.isKeyWindow == true else { self?.stopRepeat(); return }
                self.held?.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        held = (code, timer, send)
    }

    private func stopRepeat() {
        held?.timer.invalidate()
        held = nil
    }

    /// Not a control character, nor one of the private-use ones the Mac's function keys (F1, Home, Page Up…) carry.
    private static func printable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
#endif
