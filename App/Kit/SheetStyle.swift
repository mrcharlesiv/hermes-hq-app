// [m9/ipad] How a phone-shaped sheet (Bot Info, Settings, New Bot, Group Info, a Kanban task) is presented
// (docs/spec/3x-ipad.md §4.8, D6): in two panes the system's centred form sheet, so its rows keep a phone's width
// instead of stretching across the window (UX study #161); otherwise the page sheet with its detents, as on the phone.

import ObjectiveC
import SwiftUI
import UIKit

@MainActor enum SheetStyle {
    /// `presenter`: whoever presents the sheet (its window says the layout); nil reads the app's tabs.
    /// `fixed` ([mac] only): the sheet keeps this height (at most the tall size) whatever its page holds, for a sheet
    /// whose tabs change its list (Bot Info), so switching tabs never changes its height; the page scrolls instead.
    static func apply(_ navigation: UINavigationController, from presenter: UIViewController?,
                      detents: [UISheetPresentationController.Detent] = [.large()], fixed: CGFloat? = nil) {
        if PanePopover.take(navigation, detents: detents) { return }   // [ipad-polish] hung off its button in two panes
        navigation.modalPresentationStyle = twoPanes(presenter) ? .formSheet : .pageSheet
        navigation.sheetPresentationController?.detents = detents
        #if targetEnvironment(macCatalyst)
        // [mac] The form sheet keeps the iPad's 620 × 700 pt in any window, so a Kanban task or Bot Info scrolled with
        // most of the window empty. On the Mac it's as tall as the window allows, at the same width (owner 2026-10-23).
        if navigation.modalPresentationStyle == .formSheet, let window = presentingWindow(presenter) {
            let tall = macTallHeight(window)
            navigation.preferredContentSize = CGSize(width: 620, height: min(tall, fixed ?? tall))
            // [macpass-popups r3] Bot Info in a 900 x 600 window opened 581 px tall, 9 px from the window's top: its
            // bar stood past the tall size (`MacSheetFit.keepUnder`).
            MacSheetFit.keepUnder(navigation, set: min(tall, fixed ?? tall), tall: tall, floor: 320)
            if let fixed { MacSheetEdges.asked(navigation, height: fixed) }   // what it grows back to in a bigger window
            if fixed == nil { MacSheetFit.attach(to: navigation, tall: tall) }
        }
        #else
        // [ipad-polish] The iPad's own form sheet is 570 × 650 pt whatever the window, so on a 13-inch iPad Bot Info
        // showed its header and two rows, and Settings stopped after Appearance, in a card a quarter of the screen. A
        // full-height sheet (Bot Info, Settings, Edit Bot, a Kanban task) is now as tall as the window allows, at a
        // phone's width, and follows its page the way the Mac's does: a short form stays short. Sheets that open at
        // half height keep the system's card.
        if navigation.modalPresentationStyle == .formSheet, detents.allSatisfy({ $0.identifier == .large }),
           let window = presentingWindow(presenter) {
            let tall = max(650, min(window.bounds.height - 140, 1000))
            navigation.preferredContentSize = CGSize(width: 620, height: tall)
            MacSheetFit.attach(to: navigation, tall: tall)
        }
        #endif
    }

    /// [mac] A sheet that sizes itself with detents and no navigation controller (the Update Add-on and Update Hermes
    /// sheets): the Mac ignores detents, so it stayed the system's small form sheet and its steps scrolled, crammed
    /// (owner 2026-11-07). On the Mac it is the other sheets' size: 620 wide, as tall as the window allows.
    static func macTall(_ controller: UIViewController, from presenter: UIViewController?) {
        #if targetEnvironment(macCatalyst)
        guard let window = presentingWindow(presenter) else { return }
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 620, height: macTallHeight(window))
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] A full-height sheet's height: as tall as the window allows, at most 1,100 pt. [macpass-popups]
    /// Never taller than the window it opens over, less 60 pt above and below: the 700 pt floor made a sheet over a
    /// smaller window (Add Gateway over the Settings window) taller than the window, over its close, minimise and zoom
    /// buttons, with Sign In cut off at the foot.
    static func macTallHeight(_ window: UIWindow) -> CGFloat {
        macTallHeight(room: window.bounds.height)
    }

    /// [macpass-popups] A sheet that shows a document (a live page or tile, a note, a folder of files): the page size
    /// the tiles' sheet had (`HTMLPageSheet`), wide as a browser's page up to `width` (960 at most), the window less 80
    /// pt a side, and as tall as the window allows, the same every time: it does not follow its page's scrolling
    /// height as a form does (a note or a web page followed its own length; a 620 pt strip over a wide window).
    static func macPage(_ navigation: UINavigationController, width: CGFloat = 960, from presenter: UIViewController?) {
        guard let window = presentingWindow(presenter) else { return }
        navigation.view.subviews.filter { $0 is MacSheetFit }.forEach { $0.removeFromSuperview() }   // no following the page
        objc_setAssociatedObject(navigation, &MacSheetFit.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = macPageSize(window.bounds.size, width: width)
    }

    /// The page size in a window this size (`macPage`).
    static func macPageSize(_ room: CGSize, width: CGFloat = 960) -> CGSize {
        CGSize(width: max(620, min(width, 960, room.width - 160)),
               height: min(room.height - 80, max(480, min(room.height - 180, 1100))))
    }

    /// [macpass-popups r3] A sheet's height in a window `room` pt tall (`macTallHeight`). [macpass-chat r5] 60 pt of the
    /// window stay clear above and below at every size: in a window under 820 pt (900 x 600) the 700 pt floor left 40,
    /// and Bot Info's top ran up against the window's top edge (18 px from it).
    static func macTallHeight(room: CGFloat) -> CGFloat { max(320, min(room - 120, 1100)) }
    #endif

    static func inTwoPanes(_ presenter: UIViewController?) -> Bool { twoPanes(presenter) }

    /// [ipad-polish] A sheet that shows a document (a live page or tile, a note, a folder of files) is wider than a form
    /// on an iPad: up to `width`, with 40 pt of the window left on each side. A page made for a browser sat in a
    /// phone's 620 pt on a 1,366 pt screen. Only the iPad's full-height form sheet in two panes; a no-op elsewhere.
    /// [macpass-popups] On the Mac: the page size (`macPage`), up to `width`.
    static func widen(_ navigation: UINavigationController, to width: CGFloat, from presenter: UIViewController?) {
        #if targetEnvironment(macCatalyst)
        guard navigation.modalPresentationStyle == .formSheet else { return }
        macPage(navigation, width: width, from: presenter)
        #else
        guard navigation.modalPresentationStyle == .formSheet, let window = presentingWindow(presenter) else { return }
        let wide = max(620, min(width, window.bounds.width - 80))
        MacSheetFit.widen(navigation, to: wide)
        navigation.preferredContentSize.width = wide
        #endif
    }

    private static func twoPanes(_ presenter: UIViewController?) -> Bool {
        let tabs = presenter?.viewIfLoaded?.window.flatMap { AppRoot.tabs($0) } ?? MainTabController.current
        return tabs?.split?.isDouble == true
    }

    private static func presentingWindow(_ presenter: UIViewController?) -> UIWindow? {
        presenter?.viewIfLoaded?.window ?? MainTabController.current?.viewIfLoaded?.window
    }
}

/// [mac] Stress test 2026-10-28 #32: a short page (Usage & Limits, Model Prices, Changes, Commands) sat at the top of a
/// window-tall sheet. The sheet now follows its page's scrolling content, from 320 pt up to the tall size a long list
/// keeps. [ipad-polish] The iPad's full-height form sheets in two panes use it too (`SheetStyle.apply`). It waits for the content to settle (a page fills in after loading), then follows it (#80: it used to only
/// grow); while a field in it is being typed in it only grows. An empty page (its notice drawn over no rows) is 420.
@MainActor final class MacSheetFit: UIView {
    fileprivate static var key: UInt8 = 0
    private weak var navigation: UINavigationController?
    private weak var watched: UIScrollView?
    private var watch: NSKeyValueObservation?
    private var tall: CGFloat
    /// The narrowest it is: a sheet's 620, or a pop-over's own width (`PanePopover`).
    private var wide: CGFloat = 620
    /// The shortest it is: a sheet's 320, less for a pop-over of a few rows.
    private var floor: CGFloat = 320
    private var height: CGFloat = 0
    private var tries = 0
    private var settle: DispatchWorkItem?

    static func attach(to navigation: UINavigationController, tall: CGFloat, wide: CGFloat = 620, floor: CGFloat = 320) {
        let fit = MacSheetFit(navigation, tall: tall)
        fit.wide = wide
        fit.floor = floor
        objc_setAssociatedObject(navigation, &key, fit, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        fit.frame = navigation.view.bounds
        fit.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigation.view.addSubview(fit)   // its layout passes are the cue to look for the page's list
    }

    /// [mac-audit K] Owner 2026-11-02: a settings page in a sheet (Tool Calls: seven choices, most with a two-line
    /// description) followed its list to 920 pt, nearly the whole window, for a few switches. It stops at `height` and
    /// its list scrolls the rest, as a Mac preferences sheet does.
    /// [ipad-polish] The narrowest the sheet is from now on (`SheetStyle.widen`).
    static func widen(_ navigation: UINavigationController, to width: CGFloat) {
        (objc_getAssociatedObject(navigation, &key) as? MacSheetFit)?.wide = width
    }

    static func cap(_ navigation: UINavigationController, at height: CGFloat) {
        guard let fit = objc_getAssociatedObject(navigation, &key) as? MacSheetFit, height < fit.tall else { return }
        fit.tall = height
        navigation.preferredContentSize.height = min(navigation.preferredContentSize.height, height)
    }

    /// [macpass-popups r3] The window was resized: the sheet's tallest is the new window's, and it fits its page again
    /// within it (false: the sheet has no fit of its own).
    @discardableResult
    static func windowChanged(_ navigation: UINavigationController, tall: CGFloat) -> Bool {
        guard let fit = objc_getAssociatedObject(navigation, &key) as? MacSheetFit else { return false }
        let wasTall = fit.height == 0 || fit.height >= fit.tall - 1   // a page with no list of its own stays the tall size
        fit.tall = tall
        if let watched = fit.watched, fit.height > 0 {
            fit.fit(watched, settled: true)
        } else if wasTall || navigation.preferredContentSize.height > tall {
            navigation.preferredContentSize.height = tall
            keepUnder(navigation, set: tall, tall: tall, floor: fit.floor)
        }
        return true
    }

    private init(_ navigation: UINavigationController, tall: CGFloat) {
        self.navigation = navigation
        self.tall = tall
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A notice put up or taken down (an empty answer, an error) can leave the list's content size as it was.
        if let watched { follow(watched); return }
        guard let page = navigation?.topViewController?.viewIfLoaded, let scroll = Self.list(in: page, depth: 0) else {
            // The page isn’t in place yet, or keeps no list of its own: a few more looks, then it stays tall.
            tries += 1
            if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.setNeedsLayout() } }
            return
        }
        watched = scroll
        watch = scroll.observe(\.contentSize, options: [.initial]) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.follow(scroll) }
        }
    }

    /// The page's own list: the view itself, or the first tall scroll view a few levels in (a SwiftUI List's).
    /// [mac] Never the scroll view inside a page's notice (`UIContentUnavailableView`, Commands' "No Commands
    /// Available"): it fills the page to centre the notice, so a sheet following it stayed window-tall.
    private static func list(in view: UIView, depth: Int) -> UIScrollView? {
        if view is UIContentUnavailableView { return nil }
        if let scroll = view as? UIScrollView, scroll.bounds.height > 100, !(scroll is UITextView) { return scroll }
        guard depth < 6 else { return nil }
        for child in view.subviews where !child.isHidden {
            if let found = list(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// [macpass-popups] The sheet opened at the tall size and only fitted its page 0.3 s later, so New Chat (and every
    /// other fitted sheet) opened window-tall and empty, then shrank. As the sheet goes on screen its page is laid out at
    /// once and the sheet takes the page's height before it is drawn; later changes still wait for the page to settle.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, height == 0, let navigation else { return }
        #if !targetEnvironment(macCatalyst)
        // [goals step 2] The iPad's form sheet: a page whose list has its whole height at once (a goal's page, a plain
        // stack in a scroll view) fitted here, mid-presentation, and the presentation never finished: its fade stayed
        // on the sheet and every tap on it fell through to the dimming view. On the iPad it fits once it is up.
        if let coordinator = navigation.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.setNeedsLayout() }
            return
        }
        #endif
        navigation.view.layoutIfNeeded()
        guard let page = navigation.topViewController?.viewIfLoaded, let scroll = watched ?? Self.list(in: page, depth: 0) else { return }
        scroll.layoutIfNeeded()
        if scroll.contentSize.height > 0 { fit(scroll, settled: true) }
    }

    private func follow(_ scroll: UIScrollView) {
        #if !targetEnvironment(macCatalyst)
        // [goals step 2] Never mid-presentation on the iPad (see `didMoveToWindow`): once the sheet is up.
        if let coordinator = navigation?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self, weak scroll] _ in if let scroll { self?.follow(scroll) } }
            return
        }
        #endif
        // The first measure of a page that is already drawn: at once (see `didMoveToWindow`).
        if height == 0, scroll.window != nil, scroll.contentSize.height > 0 { fit(scroll, settled: true); return }
        settle?.cancel()
        relax?.cancel()   // [mac] #74: the list moved again, so it isn't still yet
        let work = DispatchWorkItem { [weak self, weak scroll] in if let scroll { self?.fit(scroll) } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// [mac] Stress test 2026-10-28 #74: how long the list must stay still while a field holds words before the sheet
    /// fits it again. Longer than the gap between keys, so it never moves per key.
    private static let typingPause: TimeInterval = 1.2
    private var relax: DispatchWorkItem?

    private func fit(_ scroll: UIScrollView, settled: Bool = false) {
        guard let navigation else { return }
        relax?.cancel()
        relax = nil
        let content = scroll.contentSize.height
        // [mac] A page showing its notice over no rows (Commands' "No Commands Available", an error) is the empty
        // page's 420, whatever the bare list's few points of padding add up to.
        let notice = navigation.topViewController?.contentUnavailableConfiguration != nil
        // An empty page's notice: 420 in a sheet, 280 in a pop-over (its `floor` is lower), where 420 was mostly air.
        let wanted = content > 0 && !notice ? content + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom : (floor < 320 ? 280 : 420)
        // Stress test 2026-10-28 #71, #74, #80: only growing kept the height of whatever showed while the page loaded
        // (Commands' skeleton rows, Prices' "Looking up list prices…"), so a settled page sat over 60 to 190 pt of empty
        // sheet, a different amount in each look. Settled, the sheet now follows its page both ways; only while
        // something is typed in it (a search narrowing the list) does it keep its height, so it doesn't jump per key.
        // [mac] #74 (round 3): the fit only ran when the list's size changed, so once a search had narrowed Model
        // Prices to one row and the typing stopped, nothing fitted it again and the sheet kept the whole list's height
        // under that row for as long as the field held its words. Now a typing floor lasts until the list has been
        // still for `typingPause`, then the sheet fits the settled list.
        let typing = !settled && Self.typing(in: navigation.view, depth: 0)
        let held = typing ? height : 0
        let next = min(tall, max(floor, held, wanted.rounded(.up)))
        let fitted = min(tall, max(floor, wanted.rounded(.up)))
        if typing, abs(next - fitted) > 1 {   // held up by the floor: fit once the list is still
            let work = DispatchWorkItem { [weak self, weak scroll] in if let scroll { self?.fit(scroll, settled: true) } }
            relax = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause, execute: work)
        }
        guard abs(next - height) > 1 || height == 0 else { return }
        height = next
        // A page that asks for more width keeps it (the Table page: a wide table's own width, up to 900).
        let width = max(wide, navigation.topViewController?.preferredContentSize.width ?? 0)
        navigation.preferredContentSize = CGSize(width: width, height: next)
        #if targetEnvironment(macCatalyst)
        // [macpass-popups r3] The sheet is its bar taller than the height it is given, and a list that runs under the
        // bar counts the bar in its top inset too: every fitted sheet stood 54 pt (42 px) of empty foot under its last
        // row (New Task: 63 px from its last row to the sheet's foot, New Job the same). The bar is counted once, and a
        // sheet capped at the tall size is the tall size with its bar.
        let bar = navigation.preferredContentSize.height - next
        if navigation.modalPresentationStyle == .formSheet, bar > 0.5 {
            var less = content > 0 && !notice ? min(bar, max(0, scroll.adjustedContentInset.top)) : 0
            if next - less + bar > tall { less = next + bar - tall }
            if less > 0.5 { navigation.preferredContentSize = CGSize(width: width, height: max(floor - bar, next - less)) }
        }
        #endif
    }

    /// [macpass-popups r3] A navigation sheet is its bar taller than the height it is given (54 pt on the Mac), so a
    /// sheet capped at the tall size stood 54 pt past it: in a 600 px window New Job was 754 of 780 pt, 10 px from the
    /// window's top and foot. Capped, it is the tall size with its bar.
    static func keepUnder(_ navigation: UINavigationController, set: CGFloat, tall: CGFloat, floor: CGFloat) {
        #if targetEnvironment(macCatalyst)
        let shown = navigation.preferredContentSize   // what was set, and the bar
        guard shown.height > tall + 0.5 else { return }
        navigation.preferredContentSize = CGSize(width: shown.width, height: max(floor, set - (shown.height - tall)))
        #endif
    }

    /// A text field in the sheet has the keyboard (a search field, the Prompts editor's fields). [mac] A search field
    /// counts only with words in it, the only time it narrows the list: an empty one holding the keyboard kept the
    /// height a loading list had reached as the floor. [mac] #74 (round 3): Model Prices' field is a SwiftUI text field
    /// in the list (`PricesMacSearch`), a plain `UITextField`, so the words-only rule never reached it: merely clicked
    /// into, it held the floor. A one-line field now counts only with words in it too; a text view always does.
    private static func typing(in view: UIView, depth: Int) -> Bool {
        if view.isFirstResponder, view.window != nil {
            if let field = view as? UITextField { return !(field.text ?? "").isEmpty }
            if view is UITextView { return true }
        }
        guard depth < 12 else { return false }
        return view.subviews.contains { typing(in: $0, depth: depth + 1) }
    }
}

/// [ipad-polish] Owner 2026-11-11 ("you can do better"): in two panes a half-height sheet that a button opens (☰'s
/// Commands, the model's Models, the title's Chat Info, ⋯'s Prompts, Sessions' New Chat) was the system's floating
/// card in the middle of the window: across the line between the list and the chat, dimming both, a hand's width from
/// the button that opened it. There it now hangs off its button as a pop-over, as the iPad's own apps do: nothing is
/// dimmed, a tap anywhere else closes it, and it is as tall as its list. One pane (and the iPhone) keeps the sheet;
/// if the window narrows while it is open the system turns it back into that sheet, detents and all.
@MainActor enum PanePopover {
    private static var next: (anchor: any UIPopoverPresentationControllerSourceItem, rect: CGRect?, arrow: UIPopoverArrowDirection,
                              size: CGSize, bar: Bool)?

    /// Call just before making the sheet (`ChatSheet.wrap`, `MenusSheet.wrap`, anything that goes through
    /// `SheetStyle.apply`): in two panes it is made a pop-over hung off `anchor`. It has to be said first because a
    /// sheet's presentation is fixed the moment its frame is made. Does nothing when this is not two panes on an iPad,
    /// when there is nothing on screen to hang it from, or when another pop-up is already over `presenter`.
    /// `rect`: the part of a view `anchor` it hangs from (a bar's button, since a pop-over given the bar's item itself
    /// grows out of the button and covers the bar). `arrow`: which way it may point (down: above the message box).
    static func hangNext(on anchor: (any UIPopoverPresentationControllerSourceItem)?, rect: CGRect? = nil,
                         arrow: UIPopoverArrowDirection = .any, from presenter: UIViewController?,
                         size: CGSize = CGSize(width: 360, height: 520), bar: Bool = true) {
        #if !targetEnvironment(macCatalyst)
        var twoPanes = SheetStyle.inTwoPanes(presenter)
        #if DEBUG
        // `-HQDebugPanePopover YES`: as in two panes, for a demo chat (`-HQDemoChat`), which has no tabs to ask.
        if UserDefaults.standard.bool(forKey: "HQDebugPanePopover"), UIDevice.current.userInterfaceIdiom == .pad { twoPanes = true }
        #endif
        guard let anchor, twoPanes, presenter?.presentedViewController == nil else { return }
        if let view = anchor as? UIView, view.window == nil || view.isHidden || view.alpha < 0.05 { return }
        let tall = min(size.height, max(320, (presenter?.viewIfLoaded?.window?.bounds.height ?? 800) - 160))
        next = (anchor, rect, arrow, CGSize(width: size.width, height: tall), bar)
        // Only the sheet made in this same turn: a caller that then makes none must not hang someone else's.
        DispatchQueue.main.async { next = nil }
        #endif
    }

    /// `SheetStyle.apply`'s first step: true when the sheet became the pop-over that was asked for.
    fileprivate static func take(_ navigation: UINavigationController, detents: [UISheetPresentationController.Detent]) -> Bool {
        guard let asked = next else { return false }
        next = nil
        navigation.modalPresentationStyle = .popover
        guard let popover = navigation.popoverPresentationController else { return false }
        popover.sourceItem = asked.anchor
        if let rect = asked.rect { popover.sourceRect = rect }
        popover.permittedArrowDirections = asked.arrow
        let adaptive = popover.adaptiveSheetPresentationController
        adaptive.detents = detents
        adaptive.prefersGrabberVisible = false
        navigation.preferredContentSize = asked.size
        // The pop-over's own Liquid Glass with the rows on their soft cards, as the half-height sheets are on the
        // iPhone (`GlassSheetTrait`).
        if Theme.isDesktop {
            // The look's raised surface, a step lighter than the page, inside the pop-over's own thin rim: on the
            // page's colour with no rim a pop-over had no edge at all and its rows read as part of the page behind.
            navigation.view.backgroundColor = ChatPalette.elevated.withAlphaComponent(0.94)
        } else {
            navigation.traitOverrides[GlassSheetTrait.self] = true
            // Glass alone let a chat's coloured bubbles show through the rows (blue behind a model's price); a veil
            // of the page's own colour over it keeps the glass at the edges and the words on a quiet ground.
            navigation.view.backgroundColor = HQPalette.page.withAlphaComponent(0.82)
        }
        // `bar: false`: a pop-over with nothing in its bar but a name its button already says (Chat Info under the
        // chat's title, New Chat under the compose button) starts at its first row.
        navigation.additionalSafeAreaInsets.bottom = 10   // the last card clear of the pop-over's bottom edge
        if !asked.bar {
            navigation.setNavigationBarHidden(true, animated: false)
            navigation.additionalSafeAreaInsets.top = 8   // the first row clear of the pop-over's rounded corner
        }
        MacSheetFit.attach(to: navigation, tall: asked.size.height, wide: asked.size.width, floor: 120)
        // A pop-over closes with a tap outside it: its ✕ or Cancel would be a second way on the same page.
        if let item = navigation.viewControllers.first?.navigationItem, let close = item.leftBarButtonItem,
           ["sheet.close", "sheet.cancel"].contains(close.accessibilityIdentifier ?? "") {
            item.leftBarButtonItem = nil
        }
        return true
    }
}

extension UINavigationBar {
    /// [ipad-polish] Where the bar's trailing-most button sits (Sessions' compose, a chat's ⋯), for a pop-over to hang
    /// under: given the bar's item itself, a pop-over grows out of the button and covers the page's title.
    var hqTrailingButtonRect: CGRect {
        let side: CGFloat = 44, inset: CGFloat = 16
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return CGRect(x: rightToLeft ? inset : bounds.maxX - inset - side, y: bounds.midY - side / 2, width: side, height: side)
    }
}

extension UIBarButtonItem {
    /// The item a sheet or viewer closes with. iPhone: the system's item (✕, Cancel, Done), as before. [mac] Stress test
    /// 2026-10-28 #55: on the Mac the system's items draw as a ✕ or ✓ in a circle, and sheets and viewers closed three
    /// ways (✕, a grey Done, a glass Done). Every one now ends in a word, Cancel for a form that throws away its edits and
    /// Done otherwise, in the label colour: the Desktop Look's grey bar tint made Done read as switched off.
    static func hqClose(_ item: SystemItem = .close, action: UIAction?) -> UIBarButtonItem {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55 (round 6): a titled bar item's words are drawn by the bar, which took their
        // colour from the bar's tint chain whatever the item said (round 2's title attributes kept their font, not their
        // colour: Done stayed mid-grey in both looks, luminance 93 against the title's 35). The word is now the item's
        // own button with its own foreground, which no tint reaches: the label colour, Done semibold as the Mac's default
        // button, Cancel regular, label 3 while switched off.
        let word = item == .cancel ? "Cancel" : "Done"
        let close = MacCloseItem(word: word, semibold: item != .cancel, action: action)
        close.title = word
        return close
        #else
        let close = UIBarButtonItem(systemItem: item, primaryAction: action)
        // [popup-consistency] The ✕ says "Close" to VoiceOver, as the sheets that draw their own ✕ do
        // (`SheetCloseDisc`); the system item alone said "close".
        if item == .close {
            close.accessibilityLabel = SheetCloseDisc.Glyph.close.label
            // [theme-audit] Give the system close glyph the skin's primary ink on custom skins (including dark-only
            // skins under light system appearance) so it never inherits system black-on-dark.
            if !Theme.isStandard(Theme.shared.state) { close.tintColor = HQPalette.label }
        }
        return close
        #endif
    }

    /// A sheet's bar item that is a plain word beside Done (Bot Info's Edit): the system's titled item. [mac] Mac polish
    /// #70: on the Mac drawn as Done is (`MacCloseItem`), in the label colour at Done's size, regular weight, label 3
    /// while switched off. The bar's tint drew it smaller and grey, so it read as switched off when it worked.
    static func hqWord(_ word: String, action: UIAction?) -> UIBarButtonItem {
        #if targetEnvironment(macCatalyst)
        let item = MacCloseItem(word: word, semibold: false, action: action)
        item.title = word
        return item
        #else
        return UIBarButtonItem(title: word, primaryAction: action)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #55 (round 6): a sheet's Done or Cancel as a plain button in the label colour (see
/// `hqClose`). Switching the item off switches its button off, as a titled item's words would grey.
final class MacCloseItem: UIBarButtonItem {
    /// The words' font: also the Find bar's Done (`ChatFindBar`), so every Done on the Mac is one size and weight.
    /// [mac] Stress test 2026-10-28 round 7: the sheet title's size (`MacType.pageTitle`), as a Mac sheet has, never
    /// larger. The Menus sheets' body font (`menusFont`) is scaled for a large text size of its own, so Done stood
    /// visibly bigger than the title beside it (Chat Info).
    static func font(semibold: Bool) -> UIFont {
        let title = MacType.pageTitle
        return semibold ? title : HQFont.face(ofSize: title.pointSize, weight: .regular)
    }

    convenience init(word: String, semibold: Bool, action: UIAction?) {
        var config = UIButton.Configuration.plain()
        config.title = word
        config.baseForegroundColor = HQPalette.label
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let font = Self.font(semibold: semibold)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = font
            return copy
        }
        let button = MacCloseButton(configuration: config)
        // [mac] Stress test 2026-10-28 round 6: a sheet's bar inherits the dimmed tint mode, and a configuration button
        // draws its title at about a quarter opacity there whatever its foreground (measured: label 255,255,255@0.25).
        // Pinned to normal, so Done reads as a live button.
        button.tintAdjustmentMode = .normal
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = button.isEnabled ? HQPalette.label : HQPalette.label3
        }
        if let action { button.addAction(action, for: .primaryActionTriggered) }
        button.sizeToFit()
        self.init(customView: button)
    }

    override var isEnabled: Bool {
        didSet { (customView as? UIControl)?.isEnabled = isEnabled }
    }

    /// [mac] Stress test 2026-10-28 round 8: the sheet's title in the page-title token too. The Desktop Look's bars
    /// carry it, but the iOS look's sheets kept the system's title (13 pt cap height against Done's 15; "Chat Info" 73
    /// pt wide against 82). On the bar, the button puts the token on the sheet's bar and its page's own appearances.
    private final class MacCloseButton: UIButton {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  let bar = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? UINavigationBar }).first
            else { return }
            // Mac polish #77: the subtitle's token with the title's (`MacWindow.tokened`).
            if let next = MacWindow.tokened(bar.standardAppearance) { bar.standardAppearance = next }
            if let next = MacWindow.tokened(bar.scrollEdgeAppearance) { bar.scrollEdgeAppearance = next }
            if let next = MacWindow.tokened(bar.compactAppearance) { bar.compactAppearance = next }
            for item in bar.items ?? [] { MacWindow.titleToken(item) }
        }
    }

    // The callers name the item ("sheet.close", "Close"); the button is what UI tests and VoiceOver find.
    override var accessibilityIdentifier: String? {
        didSet { customView?.accessibilityIdentifier = accessibilityIdentifier }
    }

    override var accessibilityLabel: String? {
        didSet { customView?.accessibilityLabel = accessibilityLabel }
    }
}
#endif

// MARK: - Where a lone Done sits

/// [mac] Stress test 2026-10-28 #55: a sheet or viewer that closes with a lone Done (no Save or Add beside it) has it on
/// the trailing edge on the Mac, as a Mac sheet's default button; the iPhone keeps it leading. Sheets set their own
/// trailing items after the frame puts Done there (Copy, Edit, ⋯, a browser's tabs), so the Mac's Done is parked on the
/// page's item: every setter of the trailing items (`DesktopBack`'s hooks) puts it back at the edge, and readers ask for
/// `hqOwnRightItem(s)`, the page's own items without it. A form (Cancel with Save or Add) keeps Cancel leading.
@MainActor enum SheetClose {
    private static let parkedKey = malloc(1)!

    static func parked(on item: UINavigationItem) -> UIBarButtonItem? {
        objc_getAssociatedObject(item, parkedKey) as? UIBarButtonItem
    }

    fileprivate static func park(_ close: UIBarButtonItem?, on item: UINavigationItem) {
        objc_setAssociatedObject(item, parkedKey, close, .OBJC_ASSOCIATION_RETAIN)
    }

    /// After the page's trailing items change: the parked Done goes back to the edge (index 0 is the trailing-most).
    static func keepTrailing(_ item: UINavigationItem) {
        guard let close = parked(on: item) else { return }
        let items = item.rightBarButtonItems ?? []
        guard items.first !== close else { return }
        item.rightBarButtonItems = [close] + items.filter { $0 !== close }   // re-enters the hook, then stops here
    }
}

extension UINavigationItem {
    /// Puts a sheet's lone Done: leading on the iPhone, [mac] trailing-most on the Mac (#55), kept there.
    func hqPlaceClose(_ close: UIBarButtonItem) {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55
        if let old = SheetClose.parked(on: self), old !== close {
            SheetClose.park(nil, on: self)
            rightBarButtonItems = (rightBarButtonItems ?? []).filter { $0 !== old }
        }
        if leftBarButtonItems?.contains(where: { $0 === close }) == true { leftBarButtonItem = nil }
        SheetClose.park(close, on: self)
        SheetClose.keepTrailing(self)
        #else
        leftBarButtonItem = close
        #endif
    }

    /// A form's own close (Cancel or a Done that tucks, beside Save or Add) on the leading edge, replacing the frame's
    /// lone Done wherever it was (`ChatSheet.wrap` parks one on the Mac).
    func hqPlaceFormClose(_ close: UIBarButtonItem) {
        hqRemoveClose()
        leftBarButtonItem = close
    }

    /// Takes the lone Done away (a page pushed inside another sheet goes Back instead), wherever it sits.
    func hqRemoveClose() {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55
        if let old = SheetClose.parked(on: self) {
            SheetClose.park(nil, on: self)
            rightBarButtonItems = (rightBarButtonItems ?? []).filter { $0 !== old }
            return
        }
        #endif
        leftBarButtonItem = nil
    }

    /// The page's own trailing items, without the Mac's parked Done (#55). The iPhone has none parked.
    var hqOwnRightItems: [UIBarButtonItem] {
        let close = SheetClose.parked(on: self)
        return (rightBarButtonItems ?? []).filter { $0 !== close }
    }

    /// The page's own trailing-most item (what `rightBarButtonItem` meant before the Mac's Done joined them).
    var hqOwnRightItem: UIBarButtonItem? { hqOwnRightItems.first }
}

extension UISheetPresentationController {
    /// A page that has to stay opaque at every height (Webhooks): a colour effect is the system's way to an opaque
    /// grouped page. [mac] Mac sheets are solid already (and the API isn't there).
    func hqOpaqueGroupedPage() {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) { backgroundEffect = UIColorEffect(color: HQPalette.groupedPage) }
        #endif
    }

    /// [glass] Owner 2026-10-30 ("utilize more liquid glass, like in pop-ups"): a half-height sheet sits on the system's
    /// Liquid Glass over the chat, as iOS 26 draws it; it turns solid at full height by itself. What made these sheets
    /// opaque before (verification round 3: bubbles behind tinted the values) is handled in the page, not here: every
    /// line people read sits on a solid card (`hqGlassReady`), so only the bar and short section labels are on glass.
    /// The Desktop Look has no glass: there the sheet keeps the opaque grouped page, and turning the look on or off
    /// with the sheet open switches it (ThemeChrome.styleSheet).
    /// `everyHeight`: glass at full height too (New Job, owner 2026-10-31: "the entire pop-up should be liquid glass").
    /// iOS turns a full-height sheet solid by itself; this sheet asks for the glass as its own background instead.
    /// [sheet-over-picture] Before `hqGlassPage()`: this sheet opens over a chat, so in Dark its glass is tinted with
    /// the page colour instead of going grey, or pale with a picture behind it.
    func hqGlassOverChat() { SheetGlass.markOverChat(self) }

    func hqGlassPage(everyHeight: Bool = false) {
        SheetGlass.install()
        objc_setAssociatedObject(self, SheetGlass.key, true, .OBJC_ASSOCIATION_RETAIN)
        if everyHeight { objc_setAssociatedObject(self, SheetGlass.everyHeightKey, true, .OBJC_ASSOCIATION_RETAIN) }
        SheetGlass.apply(self, desktop: Theme.isDesktop || Theme.solidChrome)   // [paper-solid]
    }
}

/// [glass] True inside a sheet while it sits on glass: `HQPalette.sheetPage` turns clear and grouped SwiftUI lists drop
/// their page (`hqGroupedPage`), so the rows' solid cards float on the glass.
nonisolated struct GlassSheetTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "HQGlassSheet"
}

/// [glass] The trait as SwiftUI sees it: `hqGroupedPage` drops a List's page and keeps its rows solid while it is true.
struct GlassSheetEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension GlassSheetEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Bool { traitCollection[GlassSheetTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: Bool) { mutableTraits[GlassSheetTrait.self] = value }
}

extension EnvironmentValues {
    var hqGlassSheet: Bool {
        get { self[GlassSheetEnvironmentKey.self] }
        set { self[GlassSheetEnvironmentKey.self] = newValue }
    }

    /// [tasks] A List drawn on a chat's page, above its messages (the task's details on the task's chat): no page of
    /// its own, and its cards take the chat's own card fill (`ChatBaseCell.contentCardFill`), as the chat's cards do.
    var hqChatLead: Bool {
        get { self[ChatLeadEnvironmentKey.self] }
        set { self[ChatLeadEnvironmentKey.self] = newValue }
    }
}

struct ChatLeadEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

/// [glass] Which sheets sit on glass in the iOS look, and the colour effect that replaces it in the Desktop Look.
@MainActor enum SheetGlass {
    static let key = malloc(1)!
    static let stashKey = malloc(1)!
    static let everyHeightKey = malloc(1)!
    private static var installed = false

    /// Hooks every sheet's layout once (the Desktop Look's own hook in DesktopEdges only exists while the look is on;
    /// both chain to the original whichever was installed first).
    static func install() {
        guard !installed else { return }
        installed = true
        let type: AnyClass = UISheetPresentationController.self
        let selector = #selector(UIPresentationController.containerViewDidLayoutSubviews)
        let hook = #selector(UISheetPresentationController.hqGlassContainerViewDidLayoutSubviews)
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
    }

    static func isGlassPage(_ sheet: UISheetPresentationController) -> Bool {
        objc_getAssociatedObject(sheet, key) != nil
    }

    /// A glass page that stays glass at full height (`hqGlassPage(everyHeight:)`).
    static func isGlassEveryHeight(_ sheet: UISheetPresentationController) -> Bool {
        objc_getAssociatedObject(sheet, everyHeightKey) != nil
    }

    /// [glass-design] A sheet that keeps its own page and background (How Voice Works) but carries `GlassSheetTrait`.
    private static let traitOnlyKey = malloc(1)!

    static func markTraitOnly(_ sheet: UISheetPresentationController) {
        objc_setAssociatedObject(sheet, traitOnlyKey, true, .OBJC_ASSOCIATION_RETAIN)
    }

    /// [sheet-over-picture] A glass page that opens over a chat (`hqGlassOverChat()`): the Add context sheet.
    private static let overChatKey = malloc(1)!

    static func markOverChat(_ sheet: UISheetPresentationController) {
        objc_setAssociatedObject(sheet, overChatKey, true, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Owner 2026-11-18, of the Add context sheet in Dark: "the buttons are black and the pop up is light". Plain
    /// glass in Dark is a mid grey over a plain chat and a pale wash over a bright chat picture (as the message bar
    /// was), with the sheet's dark cards standing black on it. Such a sheet's glass takes the page colour at the bar's
    /// strength (`ChatBarGlass.alpha`) in Dark, with or without a picture. Nil is the system's plain glass: Light.
    private static func overChatEffect(_ sheet: UISheetPresentationController) -> UIVisualEffect? {
        let traits = sheet.presentedViewController.traitCollection
        guard objc_getAssociatedObject(sheet, overChatKey) != nil, traits.userInterfaceStyle == .dark else { return nil }
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = ChatPalette.page.resolvedColor(with: traits).withAlphaComponent(ChatBarGlass.alpha)
        return glass
    }

    static func tracksGlass(_ sheet: UISheetPresentationController) -> Bool {
        isGlassPage(sheet) || objc_getAssociatedObject(sheet, traitOnlyKey) != nil
    }

    /// Look on: an opaque page (grouped for our glass pages, the plain page for any other sheet that would otherwise
    /// show the system's glass, e.g. How Voice Works). Look off: our glass pages go back to glass, any other sheet
    /// gets back exactly what it had.
    static func apply(_ sheet: UISheetPresentationController, desktop: Bool) {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 26.1, *) else { return }
        let ours = isGlassPage(sheet)
        if desktop {
            if !ours, objc_getAssociatedObject(sheet, stashKey) == nil {
                objc_setAssociatedObject(sheet, stashKey, Box(sheet.backgroundEffect), .OBJC_ASSOCIATION_RETAIN)
            }
            if ours || sheet.backgroundEffect == nil {
                sheet.backgroundEffect = UIColorEffect(color: ours ? HQPalette.groupedPage : HQPalette.page)
            }
        } else if ours {
            sheet.backgroundEffect = overChatEffect(sheet)
        } else if let stash = objc_getAssociatedObject(sheet, stashKey) as? Box {
            sheet.backgroundEffect = stash.effect
            objc_setAssociatedObject(sheet, stashKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        #endif
        layout(sheet)
    }

    /// After every layout of the sheet (and every look change): the page is clear only while the glass is there. At
    /// full height iOS draws the sheet solid, and an iPad's form sheet is solid too; there the page takes its grouped
    /// colour back, so the cards never sit on a page of their own colour.
    static func layout(_ sheet: UISheetPresentationController) {
        guard tracksGlass(sheet) else { return }
        let page = sheet.presentedViewController
        var glass = !Theme.isDesktop && !Theme.solidChrome && !DeviceWord.isMac && page.traitCollection.horizontalSizeClass == .compact   // [paper-solid]
        if glass, !isGlassEveryHeight(sheet), let frame = sheet.presentedView?.frame, let container = sheet.containerView,
           container.bounds.height > 0 {
            // Below full height. [glass-design] Measured from the status bar, not as a fifth of the screen: How Voice
            // Works' fitted height starts at 17 % and is glass there (full height starts about 10 pt under the bar).
            glass = frame.minY > container.safeAreaInsets.top + 40
        }
        // Reading an override that was never set traps, so ask first.
        let now = page.traitOverrides.contains(GlassSheetTrait.self) && page.traitOverrides[GlassSheetTrait.self]
        if now != glass { page.traitOverrides[GlassSheetTrait.self] = glass }
        backdrop(sheet, shown: glass)
    }

    private static let backdropKey = malloc(1)!

    private static let clearedKey = malloc(1)!

    /// [glass] A sheet that is glass at every height (`hqGlassPage(everyHeight:)`): the real `UIGlassEffect`, behind
    /// everything on the sheet (its bar too), with the sheet's own corners. Hidden wherever the page is opaque (the
    /// Desktop Look, the iPad's form sheet).
    private static func backdrop(_ sheet: UISheetPresentationController, shown: Bool) {
        guard isGlassEveryHeight(sheet), let host = sheet.presentedViewController.viewIfLoaded else { return }
        // iOS turns a full-height sheet solid, and takes a glass effect there without drawing it (the page went clear
        // over the screen behind, at the presentation and the detent alike). So while this glass shows, the system's
        // background is clear; wherever it doesn't, the system's own (only on a change: setting detents lays out again).
        let cleared = objc_getAssociatedObject(sheet, clearedKey) as? Bool ?? false
        #if !targetEnvironment(macCatalyst)   // a detent's own background is iOS-only
        if #available(iOS 26.1, *), cleared != shown {
            objc_setAssociatedObject(sheet, clearedKey, shown, .OBJC_ASSOCIATION_RETAIN)
            for detent in sheet.detents { detent.backgroundEffect = shown ? UIColorEffect(color: .clear) : nil }
            sheet.detents = sheet.detents
        }
        #endif
        var glass = objc_getAssociatedObject(sheet, backdropKey) as? UIVisualEffectView
        if glass == nil, shown {
            let made = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            made.frame = host.bounds
            made.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            made.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
            made.isUserInteractionEnabled = false
            made.accessibilityElementsHidden = true
            host.insertSubview(made, at: 0)
            objc_setAssociatedObject(sheet, backdropKey, made, .OBJC_ASSOCIATION_RETAIN)
            glass = made
        }
        guard let glass else { return }
        if glass.isHidden == shown { glass.isHidden = !shown }
        if glass.superview === host, host.subviews.first !== glass { host.sendSubviewToBack(glass) }
    }

    private final class Box: NSObject {
        let effect: UIVisualEffect?
        init(_ effect: UIVisualEffect?) { self.effect = effect }
    }
}

extension UISheetPresentationController {
    @objc dynamic func hqGlassContainerViewDidLayoutSubviews() {
        hqGlassContainerViewDidLayoutSubviews()   // the original (the implementations were exchanged)
        SheetGlass.layout(self)
        #if targetEnvironment(macCatalyst)
        MacSheetEdges.apply(self)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// [macpass-popups] Owner 2026-11-14: "not enough padding on edges of pop up windows". Every Mac sheet laid its page
/// out with the iPad's margins, which the Mac draws at 77 %: the cards and fields 16 px from the sheet's sides, the bar's
/// Done and Cancel 13 px, the last row flush on the rounded foot. A Mac sheet keeps its content about 20 px in. One
/// place puts every sheet's page that far in (Bot Info, New Bot, the Update sheets, Keyboard Shortcuts, a Kanban task,
/// the system-styled sheets that never pass `SheetStyle`): extra safe area on the presented controller, which its bar,
/// its UIKit and SwiftUI lists and anything laid out on the safe area or the layout margins follow.
/// A page that is a picture or a web page edge to edge (`fullBleed`) keeps its edges. The iPhone and iPad are unchanged.
@MainActor enum MacSheetEdges {
    /// The sides: measured on the Mac, cards, fields and the bar's Cancel / Done sit at this + 16 pt, so 10 pt puts all
    /// of them 26 pt in = 20 px on screen, one line (they sat at 16 px, Cancel / Done at 13 px).
    static let side: CGFloat = 10
    /// The foot: the last row clear of the sheet's rounded bottom edge.
    static let foot: CGFloat = 8
    private static let fullBleedKey = malloc(1)!
    private static let appliedKey = malloc(1)!
    private static let module = String(String(reflecting: MacSheetEdges.self).prefix { $0 != "." })

    /// Hooks every sheet's layout (`SheetGlass`'s hook), at launch.
    static func install() { SheetGlass.install() }

    /// A sheet whose page fills it edge to edge (a live page or tile, a picture): no extra edges.
    static func fullBleed(_ controller: UIViewController) {
        objc_setAssociatedObject(controller, fullBleedKey, true, .OBJC_ASSOCIATION_RETAIN)
        guard objc_getAssociatedObject(controller, appliedKey) != nil else { return }
        objc_setAssociatedObject(controller, appliedKey, nil, .OBJC_ASSOCIATION_RETAIN)
        controller.additionalSafeAreaInsets.left -= side
        controller.additionalSafeAreaInsets.right -= side
        controller.additionalSafeAreaInsets.bottom -= foot
    }

    static func apply(_ sheet: UISheetPresentationController) {
        let page = sheet.presentedViewController
        followWindow(sheet)
        guard objc_getAssociatedObject(page, fullBleedKey) == nil,
              !(page is UIAlertController), page.modalPresentationStyle != .popover else { return }
        if objc_getAssociatedObject(page, appliedKey) == nil {
            // Only the app's own pages: the system's (Quick Look, pickers, Share) lay themselves out.
            let first = (page as? UINavigationController)?.viewControllers.first ?? page
            // (A SwiftUI page's hosting controller is SwiftUI's class, named for the app's view inside it.)
            guard Bundle(for: type(of: first)) == Bundle.main || NSStringFromClass(type(of: first)).contains(module) else { return }
            // A navigation controller whose first page is full bleed.
            if objc_getAssociatedObject(first, fullBleedKey) != nil { return }
            objc_setAssociatedObject(page, appliedKey, true, .OBJC_ASSOCIATION_RETAIN)
            page.additionalSafeAreaInsets.left += side
            page.additionalSafeAreaInsets.right += side
            page.additionalSafeAreaInsets.bottom += foot
        }
        if let root = page.viewIfLoaded { pinScrollBarsToEdge(in: root) }
    }

    /// `additionalSafeAreaInsets` pushes UIScrollView's vertical scroll bar `side` pt inward from the sheet's edge,
    /// right up against grouped cards. Pull full-width vertical scroll indicators back out to the sheet edge.
    private static func pinScrollBarsToEdge(in root: UIView) {
        let rightEdge = root.bounds.maxX
        let leftEdge = root.bounds.minX
        guard rightEdge - leftEdge > 1 else { return }
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.showsVerticalScrollIndicator,
               scroll.automaticallyAdjustsScrollIndicatorInsets, !scroll.isHidden {
                let frame = scroll.convert(scroll.bounds, to: root)
                let rtl = scroll.effectiveUserInterfaceLayoutDirection == .rightToLeft
                if rtl {
                    if frame.minX <= leftEdge + 2, scroll.safeAreaInsets.left >= side - 0.5,
                       abs(scroll.verticalScrollIndicatorInsets.left - (-side)) > 0.5 {
                        scroll.verticalScrollIndicatorInsets.left = -side
                    }
                } else {
                    if frame.maxX >= rightEdge - 2, scroll.safeAreaInsets.right >= side - 0.5,
                       abs(scroll.verticalScrollIndicatorInsets.right - (-side)) > 0.5 {
                        scroll.verticalScrollIndicatorInsets.right = -side
                    }
                }
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
    }

    /// [macpass-popups r3] A sheet's size was worked out once, from the window it opened over: one opened in a tall
    /// window kept its 834 pt when the window was made 600 tall, running off the window's top and foot, and one opened
    /// in a small window stayed small when it grew. Every sheet of the app's own now follows its window (the tiles'
    /// `HTMLPageSheet` did this for itself): a form fits its page again under the new window's tallest, a page sized
    /// as a document (`macPage`) takes the page size for the new window, and any other sheet is never taller than the
    /// window less 40 pt above and below, back up to the size it opened at as the window grows.
    private static let roomKey = malloc(1)!
    private static let openedKey = malloc(1)!

    private static let probeKey = malloc(1)!

    /// Once per sheet: a probe in the window it opened over (the sheet's own container is the sheet's own window on
    /// the Mac, so it never hears the main window), which goes when the sheet does.
    private static func followWindow(_ sheet: UISheetPresentationController) {
        let page = sheet.presentedViewController
        guard objc_getAssociatedObject(page, probeKey) == nil, page.modalPresentationStyle == .formSheet,
              !(page is UIAlertController), let window = sheet.presentingViewController.viewIfLoaded?.window else { return }
        let probe = WindowSizeProbe(frame: window.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        probe.changed = { [weak page, weak probe] room in
            guard let page, page.presentingViewController != nil else { probe?.removeFromSuperview(); return }
            DispatchQueue.main.async { [weak page] in if let page { windowResized(page, room: room) } }
        }
        objc_setAssociatedObject(page, probeKey, ProbeOwner(probe), .OBJC_ASSOCIATION_RETAIN)
        window.insertSubview(probe, at: 0)
    }

    /// Takes the probe out of the window when the sheet's page goes.
    private final class ProbeOwner: NSObject {
        weak var probe: UIView?
        init(_ probe: UIView) { self.probe = probe }
        deinit {
            let probe = probe
            DispatchQueue.main.async { MainActor.assumeIsolated { probe?.removeFromSuperview() } }
        }
    }

    private static func windowResized(_ page: UIViewController, room: CGSize) {
        guard room.width > 0, room.height > 0 else { return }
        let opened = objc_getAssociatedObject(page, openedKey) as? NSValue
        guard let last = (objc_getAssociatedObject(page, roomKey) as? NSValue)?.cgSizeValue, let opened else {
            objc_setAssociatedObject(page, roomKey, NSValue(cgSize: room), .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(page, openedKey, NSValue(cgSize: page.preferredContentSize), .OBJC_ASSOCIATION_RETAIN)
            return
        }
        guard abs(last.width - room.width) > 0.5 || abs(last.height - room.height) > 0.5 else { return }
        objc_setAssociatedObject(page, roomKey, NSValue(cgSize: room), .OBJC_ASSOCIATION_RETAIN)
        let size = page.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let tall = SheetStyle.macTallHeight(room: room.height)
        if let navigation = page as? UINavigationController, MacSheetFit.windowChanged(navigation, tall: tall) { return }
        let wasPage = abs(size.width - SheetStyle.macPageSize(last).width) < 1 && abs(size.height - SheetStyle.macPageSize(last).height) < 1
            && size.width > 620
        if wasPage {
            let next = SheetStyle.macPageSize(room)
            if page.preferredContentSize != next { page.preferredContentSize = next }
            return
        }
        if let asked = objc_getAssociatedObject(page, askedKey) as? CGFloat {
            // A sheet of a set height (Bot Info): that height, the bar on top, never past the window's tall size.
            let set = min(asked, tall)
            page.preferredContentSize = CGSize(width: size.width, height: set)
            if let navigation = page as? UINavigationController { MacSheetFit.keepUnder(navigation, set: set, tall: tall, floor: 320) }
            return
        }
        // The size the page asked for: the one it opened at, or one it set since (not one set here).
        var wanted = opened.cgSizeValue
        if let ours = (objc_getAssociatedObject(page, setKey) as? NSValue)?.cgSizeValue, ours != size { wanted = size }
        if objc_getAssociatedObject(page, setKey) == nil, size != wanted { wanted = size }
        objc_setAssociatedObject(page, openedKey, NSValue(cgSize: wanted), .OBJC_ASSOCIATION_RETAIN)
        let next = CGSize(width: min(wanted.width, max(320, room.width - 80)), height: min(wanted.height, max(240, room.height - 80)))
        objc_setAssociatedObject(page, setKey, NSValue(cgSize: next), .OBJC_ASSOCIATION_RETAIN)
        guard abs(next.width - size.width) > 0.5 || abs(next.height - size.height) > 0.5 else { return }
        page.preferredContentSize = next
        // A navigation sheet reads back its bar on top of what it was given: given that much less, it is `next`.
        let extra = page.preferredContentSize.height - next.height
        if extra > 0.5 { page.preferredContentSize = CGSize(width: next.width, height: next.height - extra) }
    }
    private static let setKey = malloc(1)!
    private static let askedKey = malloc(1)!

    /// The height a sheet of a set height asked for (`SheetStyle.apply`'s `fixed`), kept for when its window changes.
    static func asked(_ page: UIViewController, height: CGFloat) {
        objc_setAssociatedObject(page, askedKey, height, .OBJC_ASSOCIATION_RETAIN)
    }
}
#endif

extension UITableViewCell {
    /// [glass] Keeps a grouped row's card solid while its sheet sits on glass (`HQPalette.sheetCard`); a pressed or
    /// picked row keeps the system's highlight, and off the glass the row is exactly the table's default. [glass-design]
    /// Its section gets the cards' thin edge there (`GlassCardOutliner`).
    func hqSolidOnGlass() {
        configurationUpdateHandler = { cell, state in
            guard state.traitCollection[GlassSheetTrait.self] else { return }
            var background = cell.backgroundConfiguration ?? cell.defaultBackgroundConfiguration()
            background = background.updated(for: state)
            if !state.isHighlighted && !state.isSelected { background.backgroundColor = HQPalette.sheetCard }
            cell.backgroundConfiguration = background
            cell.hqEdgeOnGlass()
        }
        setNeedsUpdateConfiguration()
    }
}
