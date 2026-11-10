import UIKit
import UniformTypeIdentifiers

/// The composer's text view: Paste with an image on the pasteboard attaches it (docs/spec/1x-attachments.md §4.5);
/// text pastes as before. Edit-menu Paste is user-initiated, so iOS shows no paste prompt.
final class ComposerTextView: UITextView {
    /// Image item providers pasted into the field (nil: images aren't accepted here).
    var onPasteImages: (([NSItemProvider]) -> Void)?
    /// [mac] Files pasted into the field: a Finder copy (which also carries the file's name as text) or a copy in
    /// Files. Nil: files aren't accepted here.
    var onPasteFiles: (([NSItemProvider]) -> Void)?
    /// The drag over the field brings files or pictures: its drop attaches them (`UITextDropDelegate` below).
    fileprivate var dropAttaches = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier,
                                                                               UTType.text.identifier, UTType.url.identifier,
                                                                               UTType.fileURL.identifier])
        textDropDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Edge fade (accessibility sizes)

    /// At accessibility sizes, while the draft scrolls, the lines under the top and bottom insets fade out: a line the
    /// scroll cut through showed half drawn against the field's rounded edge.
    private var edgeFade: CAGradientLayer?

    override var isScrollEnabled: Bool {
        didSet { if isScrollEnabled != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        settleOnLastLine()
        updateEdgeFade()   // a scroll view lays out on every scroll: the mask follows the visible bounds
    }

    /// UIKit scrolls only the caret's own line into view, not the inset under it: with the caret on the last line the
    /// field stopped short of its foot, the line's descenders cut at the edge and half a line showing at the top. Close
    /// to the foot with the caret on the last line, the field goes the rest of the way.
    private func settleOnLastLine() {
        guard isScrollEnabled, isFirstResponder, !isTracking, !isDecelerating, let end = selectedTextRange?.end else { return }
        let bottom = contentSize.height - bounds.height + adjustedContentInset.bottom
        let short = bottom - contentOffset.y
        guard short > 0.5, short <= textContainerInset.bottom + (font?.lineHeight ?? 20) * 0.5,
              caretRect(for: end).maxY >= contentSize.height - textContainerInset.bottom - 1 else { return }
        contentOffset.y = bottom
    }

    private func updateEdgeFade() {
        guard isScrollEnabled, traitCollection.preferredContentSizeCategory.isAccessibilityCategory, bounds.height > 0 else {
            if edgeFade != nil { layer.mask = nil; edgeFade = nil }
            return
        }
        let fade = edgeFade ?? CAGradientLayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = bounds.height
        // The cut line is up to a whole line tall, not just the inset: the band covers the inset and most of a line, and
        // only on a side where the draft goes on past the edge.
        let band = min(0.3, (textContainerInset.top + (font?.lineHeight ?? 20) * 0.7) / h)
        let above = contentOffset.y > -adjustedContentInset.top + 0.5
        let below = contentOffset.y < contentSize.height - h + adjustedContentInset.bottom - 0.5
        let top = above ? band : 0, bottom = below ? band : 0
        fade.frame = bounds
        fade.colors = [(above ? UIColor.clear : UIColor.black).cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
                       (below ? UIColor.clear : UIColor.black).cgColor]
        fade.locations = [0, NSNumber(value: top), NSNumber(value: 1 - bottom), 1]
        if edgeFade == nil { edgeFade = fade; layer.mask = fade }
        CATransaction.commit()
    }

    // MARK: [m9/ipad] Hardware keyboard (docs/spec/3x-ipad.md §4.10, App/Root/KeyCommands.swift)

    /// A hardware keyboard's Return: sends what the Send button would (true = handled). Nothing to send: `nil`.
    /// `command`: ⌘Return, which does what Return doesn't while a reply runs (queues, or steers when Settings › Chat ›
    /// Send While Replying is Queue).
    var onHardwareReturn: ((_ command: Bool) -> Void)?
    /// Whether there is something to send besides the field's text (attachments, a memo chip).
    var hasMoreToSend: (() -> Bool)?
    /// [m9/composer] A hardware Return with nothing to send (the key is swallowed either way): the chat decides
    /// whether a waiting queue row goes out (`EmptyReturn`, docs/spec/3x-composer.md §1.2).
    var onHardwareReturnEmpty: (() -> Void)?

    // MARK: [composer-drawers] The slash / @ drawer's keys (docs/spec/3x-composer.md §9.5)

    enum DrawerKey { case up, down, tab }
    /// Whether the drawer above the field is open (↑ ↓ Tab are its keys then).
    var drawerOpen: (() -> Bool)?
    var onDrawerKey: ((DrawerKey) -> Void)?
    /// Return with a drawer row highlighted picks it (true = handled; Return does nothing else).
    var onHardwareReturnPick: (() -> Bool)?
    /// [groups] Escape while the list is open, for a list of its own (a group chat's @ list, `GroupRoomChrome`); nil
    /// leaves Escape to the app's ladder, which closes the bot chat's drawer (`EscapeAction.closeDrawer`).
    var onDrawerEscape: (() -> Void)?

    private lazy var drawerKeys: [UIKeyCommand] = [
        (UIKeyCommand.inputUpArrow, #selector(drawerUp)), (UIKeyCommand.inputDownArrow, #selector(drawerDown)), ("\t", #selector(drawerTab)),
    ].map { input, action in
        let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private lazy var drawerEscapeKey: UIKeyCommand = {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(drawerEscape))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()

    @objc private func drawerEscape() { onDrawerEscape?() }
    @objc private func drawerUp() { onDrawerKey?(.up) }
    @objc private func drawerDown() { onDrawerKey?(.down) }
    @objc private func drawerTab() { onDrawerKey?(.tab) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
           hardwareReturn(shift: key.modifierFlags.contains(.shift), option: key.modifierFlags.contains(.alternate),
                          command: key.modifierFlags.contains(.command)) { return }
        super.pressesBegan(presses, with: event)
    }

    /// A hardware Return (true = handled; false: the text view's own Return, which ends an input method's composition).
    private func hardwareReturn(shift: Bool, option: Bool, command: Bool) -> Bool {
        if markedTextRange == nil, !shift, !option, onHardwareReturnPick?() == true { return true }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(hasMoreToSend?() ?? false)
        let rule = ReturnKey.decide(hardware: true, shift: shift, option: option, marked: markedTextRange != nil, empty: empty)
        AppLog.note("keys", "return: \(rule)")
        switch rule {
        case .send: onHardwareReturn?(command); return true
        case .swallow: onHardwareReturnEmpty?(); return true
        case .newline: insertText("\n"); return true
        case .pass: return false
        }
    }

    /// Next / Previous Chat win over the caret's ⌘↑ / ⌘↓ only while the field is empty (D11).
    override var keyCommands: [UIKeyCommand]? {
        if drawerOpen?() == true { return drawerKeys + (onDrawerEscape == nil ? [] : [drawerEscapeKey]) + macKeys }
        let keys = (text.isEmpty ? KeyCommands.walkFromEmptyField : []) + macKeys
        return keys.isEmpty ? nil : keys
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] The Mac's text system takes Return before `pressesBegan` sees it (Return only ever added a line), so key
    /// commands get it first. Shift-, Option- and Command-Return need their own: the plain one also matched them.
    private lazy var macKeys: [UIKeyCommand] = [(UIKeyModifierFlags(), #selector(macPlainReturn)), (.shift, #selector(macShiftReturn)),
                                                (.alternate, #selector(macOptionReturn)), (.command, #selector(macCommandReturn))].map { (flags: UIKeyModifierFlags, action: Selector) in
        let command = UIKeyCommand(input: "\r", modifierFlags: flags, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func macPlainReturn() { macReturn(shift: false, option: false) }
    @objc private func macShiftReturn() { macReturn(shift: true, option: false) }
    @objc private func macOptionReturn() { macReturn(shift: false, option: true) }
    @objc private func macCommandReturn() { macReturn(shift: false, option: false, command: true) }   // the other of steer / queue

    private func macReturn(shift: Bool, option: Bool, command: Bool = false) {
        if markedTextRange != nil { unmarkText(); return }   // Return ends an input method's composition, as it does anyway
        if !hardwareReturn(shift: shift, option: option, command: command) { insertText("\n") }
    }
    #else
    private let macKeys: [UIKeyCommand] = []
    #endif

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        if action == #selector(paste(_:)), onPasteFiles != nil, pastedFiles(UIPasteboard.general) != nil { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// The pasteboard's files to attach, nil when it holds none (`AttachmentDrop.pastesFiles`).
    private func pastedFiles(_ board: UIPasteboard) -> [NSItemProvider]? {
        let providers = board.itemProviders
        guard AttachmentDrop.pastesFiles(types: providers.map(\.registeredTypeIdentifiers), hasStrings: board.hasStrings) else { return nil }
        let files = providers.filter { AttachmentDrop.attachable($0.registeredTypeIdentifiers) }
        return files.isEmpty ? nil : files
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if let onPasteFiles, let files = pastedFiles(board) {
            onPasteFiles(files)
            return
        }
        if let onPasteImages, board.hasImages {
            onPasteImages(board.itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
            // A selection holding words and a picture (a web page's): the picture attaches and the words go in, as
            // spec 1x-attachments §4.5 says (the words alone went in, the picture was dropped).
            // Typed in at the cursor (not `super.paste`, which would read the picture's providers again).
            if board.hasStrings, let words = board.string, !words.isEmpty { insertText(words) }
            return
        }
        super.paste(sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        // [mac] A file dropped on the field attaches, as one dropped on the chat does: the Finder's file URL, or on the
        // Mac the file's own type (a dropped .txt would otherwise type its contents into the field).
        let isFile: (NSItemProvider) -> Bool = { AttachmentDrop.isFile($0.registeredTypeIdentifiers) }
        var itemProviders = itemProviders
        if let onPasteFiles, itemProviders.contains(where: isFile) {
            onPasteFiles(itemProviders.filter(isFile))
            itemProviders.removeAll(where: isFile)
            if itemProviders.isEmpty { return }
        }
        guard let onPasteImages else { return super.paste(itemProviders: itemProviders) }
        let images = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let rest = itemProviders.filter { !$0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !images.isEmpty { onPasteImages(images) }
        if !rest.isEmpty { super.paste(itemProviders: rest) }
    }
}

// [mac] A file or picture dropped on the field: the field's own drop typed a text file's contents in and lost a
// picture (measured 2026-11-07 with a real drag from another app; it never reaches `paste(itemProviders:)`). With
// files or pictures among the items, the drop is ours and goes through `paste(itemProviders:)`: files and pictures
// attach, any text in the same drag is typed in. Text alone is the field's as before.
extension ComposerTextView: UITextDropDelegate {
    private func attaches(_ session: UIDropSession) -> Bool {
        guard session.localDragSession == nil else { return false }
        return session.items.contains { item in
            let types = item.itemProvider.registeredTypeIdentifiers
            if onPasteFiles != nil, AttachmentDrop.isFile(types) { return true }
            return onPasteImages != nil && !AttachmentDrop.isSnippet(types)
                && item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        dropAttaches = attaches(drop.dropSession)
        guard dropAttaches else { return drop.suggestedProposal }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropPerformer = .delegate
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard dropAttaches else { return }
        dropAttaches = false
        AppLog.note("attach", "drop on the message field: \(drop.dropSession.items.count) items")
        paste(itemProviders: drop.dropSession.items.map(\.itemProvider))
    }
}

