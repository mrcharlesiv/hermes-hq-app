import UIKit

extension UIBarButtonItem {
    /// Save, Add, Create or Send on a bar (verify round 3): the tinted capsule only while it can act; disabled it is a
    /// plain item the system dims, as iOS's own Done and Add are. A disabled prominent capsule read as enabled in dark
    /// (white words on mid-grey glass, like an enabled Edit).
    /// improve-24 #17: iOS 26 draws a disabled plain item in its own very light grey (about 1.2:1 on white) whatever its
    /// title colour or tint, so people couldn't tell Save was there. While disabled the item shows a stand-in label in
    /// the tertiary label colour instead; the item itself stays disabled, so key commands and tests read it as before.
    /// Set the title before calling this: the stand-in copies it.
    func setProminentEnabled(_ enabled: Bool) {
        if isEnabled != enabled { isEnabled = enabled }
        let next: UIBarButtonItem.Style = enabled ? .prominent : .plain
        if style != next {
            style = next
            DesktopBars.flattenBackground(of: self, desktop: Theme.isDesktop)   // the look's capsule follows the style
        }
        if enabled {
            if customView is DisabledBarTitle { customView = nil }
            return
        }
        let standIn = (customView as? DisabledBarTitle) ?? DisabledBarTitle()
        standIn.show(title ?? "", identifier: accessibilityIdentifier)
        if customView !== standIn { customView = standIn }
    }
}

/// The words of a disabled prominent bar item (`setProminentEnabled`), drawn by the app so they keep their contrast.
final class DisabledBarTitle: UILabel {
    private var fitted = CGSize.zero

    func show(_ title: String, identifier: String?) {
        text = title
        font = HQFont.preferred(.body)
        textColor = HQPalette.label3
        textAlignment = .center
        accessibilityIdentifier = identifier
        accessibilityLabel = title
        accessibilityTraits = [.button, .notEnabled]
        isAccessibilityElement = true
        // The system's own side padding: inside the glass capsule in the iOS look, none in the Desktop Look's flat bar.
        let width = ceil((title as NSString).size(withAttributes: [.font: font as Any]).width)
        fitted = CGSize(width: width + (Theme.isDesktop ? 0 : 28), height: 44)
        frame.size = fitted
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize { fitted }
    override func sizeThatFits(_ size: CGSize) -> CGSize { fitted }
    /// The bar passes its disabled item's state on to the custom view, and a disabled label fades its words again.
    override var isEnabled: Bool { get { true } set {} }
}
