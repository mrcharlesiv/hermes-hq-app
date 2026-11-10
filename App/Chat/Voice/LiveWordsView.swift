// The words as you speak (docs/spec/3x-live-words.md §4), drawn where typed words go: the composer's top row while a
// voice memo records (and in its review), and the Talk bar's top row while the bot listens. Heard words look heard,
// not typed, by more than a colour: they are set in italics (owner, 2026-11-01: no waveform before them). The newest
// words, the ones the engine may still change, are lighter. Nothing heard yet: "Listening…" holds their place. While
// they're heard it is only drawn (no caret, no keyboard); the newest words sit at the end and older ones give way behind
// "… ". A memo in review lets them be fixed (`editable`): a tap puts a caret where it landed, and what's typed is what
// the memo carries (spec §3.1.1).

import UIKit

final class LiveWordsView: UIView, UITextViewDelegate {
    private let label = UILabel()
    private(set) var text = LiveWordsText()
    /// The device is still listening: with no words yet, "Listening…" shows.
    private(set) var listening = false
    /// At most this many lines; the oldest words give way.
    var maxLines = 4 { didSet { if maxLines != oldValue { label.numberOfLines = maxLines; render() } } }
    /// The upright face the words are set from (the composer's text, the Talk bar's).
    var baseFont: UIFont = HQFont.preferred(.body) {
        didSet {
            guard baseFont != oldValue else { return }
            font = Self.italic(baseFont)
            editor?.font = font
            render()
        }
    }
    private lazy var font: UIFont = Self.italic(baseFont)

    // MARK: Fixing the words (a memo in review)

    /// The words can be fixed: a tap starts editing them. Only once nothing listens any more (a memo in review).
    var editable = false {
        didSet {
            guard editable != oldValue else { return }
            isUserInteractionEnabled = editable
            accessibilityHint = editable ? "Double-tap to fix a word." : nil
            accessibilityTraits = editable ? [.staticText, .button] : [.staticText, .updatesFrequently]
            if !editable { endEditing() }
        }
    }
    /// The words as they're being fixed, on every change.
    var onEdited: ((String) -> Void)?
    /// Its height may have changed (a line more or less while fixing): the owner lays it out again.
    var onResize: (() -> Void)?
    private var editor: UITextView?
    var isEditingWords: Bool { editor != nil }

    /// Puts a caret at `point` (in this view), or at the end.
    func beginEditing(at point: CGPoint? = nil) {
        guard editable, editor == nil else { return }
        let editor = UITextView()
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.font = font
        editor.textColor = ChatPalette.label
        editor.tintColor = ChatPalette.tint
        editor.text = text.whole
        editor.returnKeyType = .done
        editor.autocorrectionType = .yes
        editor.isScrollEnabled = false
        editor.delegate = self
        editor.accessibilityIdentifier = "voice.words.editor"
        editor.accessibilityLabel = "What You Said"
        editor.frame = bounds
        addSubview(editor)
        self.editor = editor
        label.isHidden = true
        isAccessibilityElement = false
        editor.becomeFirstResponder()
        let caret = point.flatMap { editor.closestPosition(to: convert($0, to: editor)) } ?? editor.endOfDocument
        editor.selectedTextRange = editor.textRange(from: caret, to: caret)
        onResize?()
    }

    /// Back to drawn words (the keyboard goes).
    func endEditing() {
        guard let editor else { return }
        self.editor = nil
        editor.delegate = nil
        if editor.isFirstResponder { editor.resignFirstResponder() }
        editor.removeFromSuperview()
        label.isHidden = false
        isAccessibilityElement = true
        render()
        onResize?()
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        beginEditing(at: tap.location(in: self))
    }

    override func accessibilityActivate() -> Bool {
        guard editable else { return false }
        beginEditing()
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        text = LiveWordsText(settled: textView.text)
        accessibilityValue = textView.text
        onEdited?(textView.text)
        onResize?()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
        // Return is Done: a memo's words are one run of speech.
        guard replacementText != "\n" else {
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editor === textView else { return }
            self.endEditing()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        clipsToBounds = true   // a new line shows as the view grows to it
        label.numberOfLines = maxLines
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        accessibilityIdentifier = "voice.words"
        accessibilityLabel = "What You Said"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: LiveWordsView, _) in view.render() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Italics of `font` (the face itself where it has none).
    private static func italic(_ font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// New words; the owner lays it out again (its height may change).
    func update(_ words: LiveWordsText, listening: Bool) {
        guard words != text || listening != self.listening else { return }
        // Being fixed: the editor holds them (its caret stays put).
        if editor != nil, words.whole == text.whole { return }
        text = words
        self.listening = listening
        accessibilityValue = words.isEmpty ? (listening ? "Listening" : nil) : words.whole
        render()
    }

    /// Its height at `width` for the words it holds: one line at least.
    func height(for width: CGFloat) -> CGFloat {
        if let editor {
            // Fixing: every line up to `maxLines`, then the editor scrolls.
            let whole = ceil(editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            let limit = ceil(linesHeight(maxLines))
            editor.isScrollEnabled = whole > limit + 1
            return max(ceil(linesHeight(1)), min(whole, limit))
        }
        return ceil(max(linesHeight(1), measure(fitted(width: width), width: width)))
    }

    /// `lines` lines, as the label lays them out. Lines after the first measure a little
    /// over `font.lineHeight`, so a box sized to lines × `lineHeight` dropped its last line.
    private func linesHeight(_ lines: Int) -> CGFloat {
        measure(styled(firm: Array(repeating: "Hg", count: lines).joined(separator: "\n"), fresh: ""), width: .greatestFiniteMagnitude)
    }

    /// Measured by a label like the one that draws it: `boundingRect` came out 2.5 pt short of what the label needs for
    /// two lines in the Desktop Look's 15 pt, and the label dropped the second.
    private let sizer: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    private func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        sizer.attributedText = text
        return sizer.textRect(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude), limitedToNumberOfLines: 0).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let editor, editor.frame != bounds {
            editor.frame = bounds
            if editor.isScrollEnabled, let end = editor.selectedTextRange?.end { editor.scrollRectToVisible(editor.caretRect(for: end), animated: false) }
        }
        render()
    }

    /// The words at the top, at their own height: a new line is revealed as the owner grows the view to it, never
    /// squeezed into the old height while it does.
    private func render() {
        if let editor, editor.textColor != ChatPalette.label { editor.textColor = ChatPalette.label }
        guard bounds.width > 0 else { return }
        let shown = fitted(width: bounds.width)
        if label.attributedText != shown { label.attributedText = shown }
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, ceil(measure(shown, width: bounds.width))))
        if label.frame != frame { UIView.performWithoutAnimation { label.frame = frame } }
    }

    /// The newest words that fit in `maxLines` at `width`: from the first whole word that fits, after an ellipsis.
    private func fitted(width: CGFloat) -> NSAttributedString {
        // Apple's engine can keep a whole sentence unsettled until a pause: only its newest words, the ones still
        // changing, are drawn lighter (a whole memo in grey read as disabled).
        let unsure = text.pending.split(separator: " ").map(String.init)
        let fresh = unsure.suffix(Self.freshWords).joined(separator: " ")
        let firm = LiveWordsText.join(text.settled, unsure.dropLast(Self.freshWords).joined(separator: " "))
        if firm.isEmpty && fresh.isEmpty {
            guard listening else { return NSAttributedString() }
            return styled(firm: "", fresh: "", waiting: "Listening…")
        }
        let whole = styled(firm: firm, fresh: fresh)
        guard width > 0 else { return whole }
        let limit = linesHeight(maxLines) + 1
        func fits(_ s: NSAttributedString) -> Bool { measure(s, width: width) <= limit }
        if fits(whole) { return whole }
        // Drop whole words from the front.
        let words = firm.split(separator: " ").map(String.init)
        var low = 1, high = words.count, best: NSAttributedString?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = styled(firm: "… " + words[mid...].joined(separator: " "), fresh: fresh)
            if fits(candidate) { best = candidate; high = mid - 1 } else { low = mid + 1 }
        }
        return best ?? styled(firm: "…", fresh: fresh)
    }

    /// The newest words drawn lighter, at most this many.
    static let freshWords = 2

    private func styled(firm: String, fresh: String, waiting: String? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let waiting {
            out.append(NSAttributedString(string: waiting, attributes: [.font: font, .foregroundColor: ChatPalette.label3]))
            return out
        }
        out.append(NSAttributedString(string: firm, attributes: [.font: font, .foregroundColor: ChatPalette.label]))
        if !fresh.isEmpty {
            out.append(NSAttributedString(string: firm.isEmpty ? fresh : " " + fresh,
                                          attributes: [.font: font, .foregroundColor: ChatPalette.label2]))
        }
        return out
    }
}
