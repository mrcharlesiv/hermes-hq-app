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
