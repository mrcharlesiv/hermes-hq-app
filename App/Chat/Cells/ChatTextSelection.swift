import UIKit

// [mac] Mac audit 2026-11-02 #11 (docs/mac.md, "Selecting part of a message"): on the Mac, press and drag across a
// message's text to select part of it, ⌘C or right-click › Copy Selection copies the plain words, ⌘A selects the whole message,
// and a click anywhere else puts the selection away. The text is drawn by the app (`TextKitLayout` pieces), not a text
// view, so the selection is the app's own: `MessageSelection` (App/Chat/Render/MessageSelection.swift) holds two spots in the
// message's pieces, the surfaces (a bubble's `BlockView`s, a folded reply's `TextDrawView`) draw them, and this file
// turns the mouse into spots.
//
// Rebuilt on today's renderer from F18 (fix/n20-macselect, shipped in Mac build 400, never merged); the stress test's
// simpler drag (2026-10-28 #3, `ChatBubbleCell`) lost the selection whenever a piece was redrawn, copied the drawing's
// own marks (word joiners, a code span's padding), and fought the chat's scroll for the drag.
//
// What it leaves alone: a trackpad or wheel scroll (no touches; the chat scrolls as before), a drag that starts off the
// text (scrolls), a drag in a code card or table that scrolls sideways (scrolls it), a click (links, one-click copy of
// code), the right-click menus (the message's own, with Copy for the selection first) and dragging the selection out.
// The keyboard rule: the selection never takes the keyboard from a text field (the composer). With the composer
// focused, ⌘C comes up its responder chain to the chat (`ChatViewController.copy`); with nothing holding the keyboard,
// the message's cell takes it so ⌘C and ⌘A reach it.
//
// DECISION (F18, 2026-10-26, kept): the Mac only. On the iPad a pointer's press reaches the app as a finger's (the app
// doesn't set `UIApplicationSupportsIndirectInputEvents`), so a drag on a bubble couldn't be told from a scroll.

#if targetEnvironment(macCatalyst)

/// A view that draws selectable text in pieces: a bubble's block, or a folded reply's words.
@MainActor
protocol TextSelectionSurface: UIView {
    /// The laid-out pieces, in reading order (frames in the surface's own content).
    var selectionPieces: [TextPiece] { get }
    /// Where the text is drawn, in the surface's coordinates (null without text).
    var selectionTextBounds: CGRect { get }
    /// The caret spot nearest a point in the surface's coordinates.
    func selectionSpot(at point: CGPoint) -> (piece: Int, offset: Int)?
    /// Draws each piece's selected range (by piece index); empty clears it.
    func showSelection(_ marks: [Int: NSRange], color: UIColor)
    func isOnSelection(_ point: CGPoint) -> Bool
}

extension BlockView: TextSelectionSurface {
    var selectionPieces: [TextPiece] { pieceTexts }
}

/// A folded reply's opened words: one piece, the whole view.
extension TextDrawView: TextSelectionSurface {
    var selectionPieces: [TextPiece] {
        guard !isHidden, let textKit, textKit.text.length > 0 else { return [] }
        return [TextPiece(text: textKit.text, frame: bounds)]
    }

    var selectionTextBounds: CGRect { selectionPieces.isEmpty ? .null : bounds }

    func selectionSpot(at point: CGPoint) -> (piece: Int, offset: Int)? {
        guard let textKit else { return nil }
        return (0, textKit.insertionIndex(at: point))
    }

    func showSelection(_ marks: [Int: NSRange], color: UIColor) {
        selectionColor = color
        selection = marks[0]
    }

    func isOnSelection(_ point: CGPoint) -> Bool {
        guard let textKit, let selection else { return false }
        return textKit.rects(for: selection).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }
}

/// One message's selection: the drag on its host view (the bubble, a folded reply's card), the spots, Copy and Select
/// All. One message at a time has one: a new press elsewhere puts the old one away.
@MainActor
final class ChatTextSelector: NSObject, UIGestureRecognizerDelegate {
    /// The message whose selection (or click, for ⌘A) is current.
    private(set) static weak var active: ChatTextSelector?

    private weak var host: UIView?
    /// The cell: it takes the keyboard so ⌘C and ⌘A reach it.
    private weak var owner: UIResponder?
    private let surfaces: () -> [any TextSelectionSurface]
    private let color: () -> UIColor
    /// Whether a press may start a selection (a code card or table that scrolls sideways keeps its drag).
    var canReceive: (UITouch) -> Bool = { _ in true }
    let pan = UIPanGestureRecognizer()
    private(set) var selection: MessageSelection?
    private var clearing = false

    init(host: UIView, owner: UIResponder, surfaces: @escaping () -> [any TextSelectionSurface], color: @escaping () -> UIColor) {
        self.host = host
        self.owner = owner
        self.surfaces = surfaces
        self.color = color
        super.init()
        pan.addTarget(self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        host.addGestureRecognizer(pan)
    }

    var hasSelection: Bool { selection.map { !$0.isEmpty } ?? false }
    var isActive: Bool { Self.active === self }

    /// The selection's words as plain text (nil when nothing is selected).
    var selectedText: String? {
        guard let selection, hasSelection else { return nil }
        let text = SelectionText.plain(selection, blocks: surfaces().map(\.selectionPieces))
        return text.isEmpty ? nil : text
    }

    // MARK: The drag

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        canReceive(touch)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        startsSelection(at: pressPoint())
    }

    /// Where the press was, before the pointer moved far enough to make a drag (host coordinates).
    private func pressPoint() -> CGPoint {
        guard let host else { return .zero }
        let now = pan.location(in: host), moved = pan.translation(in: host)
        return CGPoint(x: now.x - moved.x, y: now.y - moved.y)
    }

    /// A press here (host coordinates) selects: it is on the text, and not on the selection (that drags it out).
    func startsSelection(at point: CGPoint) -> Bool {
        !isOnSelection(point) && hit(point) != nil
    }

    /// The chat's own scroll asks before it takes a drag: a press on a message's text (selected or not) is the
    /// selection's or the drag-out's, not a scroll.
    func claimsPress(at point: CGPoint) -> Bool {
        isOnSelection(point) || hit(point) != nil
    }

    @objc private func dragged(_ gr: UIPanGestureRecognizer) {
        guard let host else { return }
        switch gr.state {
        case .began:
            guard begin(at: pressPoint()) else { return }
            move(to: gr.location(in: host))
        case .changed:
            move(to: gr.location(in: host))
        case .ended:
            move(to: gr.location(in: host))
            end()
        default:
            clear()
        }
    }

    // MARK: Selecting (host coordinates; the drag and MacShots come through here)

    /// A press on the text: the selection starts there, empty. Returns whether it was on text.
    @discardableResult
    func begin(at point: CGPoint) -> Bool {
        guard let spot = hit(point) else { return false }
        becomeActive()
        selection = MessageSelection(anchor: spot, focus: spot)
        apply()
        return true
    }

    /// The drag is here: the selection runs from where it began to the nearest spot in the message.
    func move(to point: CGPoint) {
        guard let host, let current = selection else { return }
        let all = surfaces()
        let candidates = all.indices.filter { !all[$0].selectionPieces.isEmpty }
        let frames = candidates.map { all[$0].convert(all[$0].bounds, to: host) }
        guard let k = SelectionGeometry.nearest(point, in: frames) else { return }
        let surface = all[candidates[k]]
        guard let spot = surface.selectionSpot(at: host.convert(point, to: surface)) else { return }
        let next = current.extended(to: TextSpot(block: candidates[k], piece: spot.piece, offset: spot.offset))
        guard next != current else { return }
        selection = next
        apply()
    }

    /// The drag let go: a selection takes the keyboard (for ⌘C, ⌘A), an empty one is put away.
    func end() {
        if hasSelection { takeKeyboard() } else { clear() }
    }

    /// ⌘A: the whole message.
    func selectAll() {
        guard let all = MessageSelection.all(lengths: surfaces().map { $0.selectionPieces.map(\.text.length) }) else { return }
        becomeActive()
        selection = all
        apply()
        takeKeyboard()
    }

    /// A plain click on the text: this message is the one ⌘A selects (nothing is selected yet).
    func focus() {
        becomeActive()
        takeKeyboard()
    }

    /// Puts the selection away; `resign` lets the cell give up the keyboard (not while it is already resigning).
    func clear(resign: Bool = true) {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }
        selection = nil
        apply()
        if Self.active === self { Self.active = nil }
        if resign, let owner, owner.isFirstResponder { owner.resignFirstResponder() }
    }

    func copySelection() {
        guard let text = selectedText else { return }
        UIPasteboard.general.string = text
        AppLog.trace("chatui", "selection copied (\(text.count) chars)")
    }

    /// Whether a point (host coordinates) is on the selected words.
    func isOnSelection(_ point: CGPoint) -> Bool {
        guard hasSelection, let host else { return false }
        return surfaces().contains { $0.isOnSelection(host.convert(point, to: $0)) }
    }

    /// The cell was configured again (streaming, a new width, reuse for the same row): its surfaces draw the selection
    /// again. A selection whose text went away is put away.
    func refresh() {
        guard selection != nil else { return }
        if surfaces().allSatisfy({ $0.selectionPieces.isEmpty }) { clear(); return }
        apply()
    }

    private func apply() {
        let all = surfaces()
        let tint = color()
        let marks = selection?.marks(lengths: all.map { $0.selectionPieces.map(\.text.length) })
        for (i, surface) in all.enumerated() { surface.showSelection(marks?[i] ?? [:], color: tint) }
    }

    private func becomeActive() {
        if let other = Self.active, other !== self { other.clear() }
        Self.active = self
        if let window = host?.window { ChatClickAway.watch(window) }
    }

    /// The caret spot a point (host coordinates) is on, when it is on a surface's text.
    private func hit(_ point: CGPoint) -> TextSpot? {
        guard let host, host.bounds.contains(point) else { return nil }
        for (i, surface) in surfaces().enumerated() where !surface.selectionPieces.isEmpty {
            let q = host.convert(point, to: surface)
            guard surface.bounds.contains(q), surface.selectionTextBounds.insetBy(dx: -8, dy: -4).contains(q),
                  let spot = surface.selectionSpot(at: q) else { continue }
            return TextSpot(block: i, piece: spot.piece, offset: spot.offset)
        }
        return nil
    }

    /// ⌘C and ⌘A: the cell takes the keyboard unless a text field (the composer) has it; then ⌘C comes up that
    /// field's responder chain to the chat instead.
    private func takeKeyboard() {
        guard let owner, !owner.isFirstResponder, !(ChatFirstResponder.current() is UITextInput) else { return }
        owner.becomeFirstResponder()
    }

    /// With a selection, the right-click menu leads with Copy Selection; the message's own Copy (the whole message)
    /// is named "Copy Message" beside it, so the two never read the same (coordinator, 2026-11-02).
    static func nameWholeCopy(in menu: UIMenu) {
        for child in menu.children {
            if let action = child as? UIAction, action.title == "Copy" { action.title = "Copy Message" }
            if let sub = child as? UIMenu { nameWholeCopy(in: sub) }
        }
    }

    /// The selector whose host a view is in (walking up from `view`), if any.
    static func owning(_ view: UIView?) -> ChatTextSelector? {
        var next = view
        while let v = next {
            if let selector = v.gestureRecognizers?.lazy.compactMap({ $0.delegate as? ChatTextSelector }).first { return selector }
            next = v.superview
        }
        return nil
    }

    /// Whether a view (walking up to the host) scrolls sideways: a code card or table that keeps its own drag.
    static func scrollsSideways(_ view: UIView?, upTo host: UIView?) -> Bool {
        var next = view
        while let v = next, v !== host {
            if let scroll = v as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return true }
            next = v.superview
        }
        return false
    }
}

/// A click anywhere in the window but on a message (which handles its own click) puts the selection away.
@MainActor
enum ChatClickAway {
    private static let watched = NSHashTable<UIWindow>.weakObjects()
    private static let gate = Gate()

    static func watch(_ window: UIWindow) {
        guard !watched.contains(window) else { return }
        watched.add(window)
        let tap = UITapGestureRecognizer(target: gate, action: #selector(Gate.clicked(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = gate
        window.addGestureRecognizer(tap)
    }

    /// A click at `point` (window coordinates); MacShots calls it as the click would.
    static func clicked(at point: CGPoint, in window: UIView) {
        guard let active = ChatTextSelector.active else { return }
        let hit = window.hitTest(point, with: nil)
        if ChatTextSelector.owning(hit) != nil { return }   // a message's own click (`ChatBubbleCell.tapped`)
        active.clear()
    }

    private final class Gate: NSObject, UIGestureRecognizerDelegate {
        @objc func clicked(_ gr: UITapGestureRecognizer) {
            guard let window = gr.view else { return }
            ChatClickAway.clicked(at: gr.location(in: window), in: window)
        }

        // The click that clears never takes a click from anything.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The app's first responder, by asking the responder chain (`sendAction` to nil reaches it first).
@MainActor
enum ChatFirstResponder {
    fileprivate static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.hqNoteFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func hqNoteFirstResponder(_ sender: Any?) { ChatFirstResponder.found = self }
}

// ⌘C and Edit › Copy with the composer holding the keyboard: the chat copies the selected words. The composer's own
// selection comes first, as it is earlier in the chain.
extension ChatViewController {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)), let active = ChatTextSelector.active, active.hasSelection { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        ChatTextSelector.active?.copySelection()
    }
}

extension ChatTableView {
    /// A press-and-drag that starts on a message's text selects it (or drags the selection out) instead of scrolling
    /// the chat. A trackpad or wheel scroll brings no touches and always scrolls.
    func textSelectionClaims(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === panGestureRecognizer, gesture.numberOfTouches > 0 else { return false }
        let now = gesture.location(in: self)
        let moved = (gesture as? UIPanGestureRecognizer)?.translation(in: self) ?? .zero
        let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
        let hit = hitTest(start, with: nil)
        guard let selector = ChatTextSelector.owning(hit), let host = selector.pan.view,
              !ChatTextSelector.scrollsSideways(hit, upTo: host) else { return false }
        return selector.claimsPress(at: convert(start, to: host))
    }
}

#endif
