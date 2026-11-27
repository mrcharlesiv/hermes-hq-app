// [mac] Previous and next in the photo viewers (Mac stress test round 2, #38): a message's second photo was a swipe
// away, which a mouse can't make. ← and → page wherever a keyboard is (key commands, harmless on the iPhone); on the
// Mac two round buttons sit at the sides while there is somewhere to go. The rule is `PhotoPaging` (HermesKit).

import UIKit

extension UIKeyCommand {
    /// ← and → for a photo pager; `action` reads which way from the command (`pagesForward`).
    static func photoPaging(_ action: Selector) -> [UIKeyCommand] {
        [(UIKeyCommand.inputLeftArrow, "Previous Photo"), (UIKeyCommand.inputRightArrow, "Next Photo")].map { input, title in
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: [])
            command.wantsPriorityOverSystemBehavior = true   // over the zooming scroll view's own arrow-key scrolling
            return command
        }
    }

    var pagesForward: Bool { input == UIKeyCommand.inputRightArrow }
}

/// [mac] The photo viewers' chrome on the Mac (owner 2026-11-18: "a weird blur on the top and bottom and it's hard to see
/// where to click to close"). The photo lives between the bars, never under their blurred edges; the bars stay put (a
/// click on the photo took Done away); Done is a filled button on the black bar. The iPhone and iPad keep the system's
/// full-screen photo under bars that a tap hides.
@MainActor enum PhotoViewerChrome {
    /// The bars stay on show when the photo is clicked.
    static var barsStay: Bool { DeviceWord.isMac }

    /// Where a page draws its photo: the whole page, or on the Mac the page between the bars (its safe area).
    static func room(_ view: UIView) -> CGRect { DeviceWord.isMac ? view.bounds.inset(by: view.safeAreaInsets) : view.bounds }

    /// A page's zooming scroll view: on the Mac no blurred edge where a zoomed photo meets the bars.
    static func prepare(_ scroll: UIScrollView) {
        guard DeviceWord.isMac else { return }
        scroll.topEdgeEffect.isHidden = true
        scroll.bottomEdgeEffect.isHidden = true
    }

    /// The viewer's close: `hqClose`, on the Mac drawn as a filled button (white 18 %, as the arrows' round buttons sit on
    /// the black; a capsule, the Desktop Look's corner there) so Done reads as something to click.
    static func close(action: UIAction) -> UIBarButtonItem {
        let close = UIBarButtonItem.hqClose(action: action)
        #if targetEnvironment(macCatalyst)
        if let button = close.customView as? UIButton, var config = button.configuration {
            config.background.backgroundColor = UIColor(white: 1, alpha: 0.18)
            config.cornerStyle = Theme.isDesktop ? .fixed : .capsule
            config.background.cornerRadius = MacPush.shapeRadius
            config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14)
            button.configuration = config
            button.sizeToFit()
        }
        #endif
        return close
    }
}

/// The Mac's previous / next buttons over a photo pager, vertically centred at its sides. Nothing on the iPhone or iPad.
@MainActor final class PhotoPagerArrows {
    private var buttons: [UIButton] = []

    /// `onStep(forward)` pages; `identifier` prefixes the buttons' accessibility identifiers.
    init(in view: UIView, identifier: String, onStep: @escaping (Bool) -> Void) {
        guard DeviceWord.isMac else { return }
        for forward in [false, true] {
            var config = UIButton.Configuration.hqGlass()   // [desktoplook3] no glass under the Desktop Look
            config.image = UIImage(systemName: forward ? "chevron.right" : "chevron.left",
                                   withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .large))
            if !Theme.isDesktop { config.cornerStyle = .capsule }
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in onStep(forward) })
            button.accessibilityLabel = forward ? "Next Photo" : "Previous Photo"
            button.accessibilityIdentifier = "\(identifier).\(forward ? "next" : "previous")"
            button.toolTip = forward ? "Next Photo (→)" : "Previous Photo (←)"
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            let guide = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
                forward ? button.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
                        : button.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            ])
            buttons.append(button)
        }
    }

    /// Shows the buttons that have a photo to go to; `hidden` (the chrome is hidden) hides both.
    func update(index: Int, count: Int, hidden: Bool) {
        for (button, forward) in zip(buttons, [false, true]) {
            let shown = !hidden && PhotoPaging.step(from: index, count: count, forward: forward) != nil
            if button.isHidden == shown { button.isHidden = !shown }
        }
    }
}
