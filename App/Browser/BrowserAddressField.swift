import UIKit

/// The viewer's address: the site's name centered, with a secure site's lock right beside it (the way Safari shows it),
/// and the whole address, left-aligned with no lock, while the person edits it. UIKit pins a text field's left view
/// to its leading edge and sizes it to its own content, so the lock is placed here instead.
final class BrowserAddressField: UITextField {
    private let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let gap: CGFloat = 4
    private let inset: CGFloat = 12

    /// A secure site: the lock shows beside its name (not while editing).
    var showsLock = false {
        didSet { if showsLock != oldValue { leftView = showsLock ? lock : nil; setNeedsLayout() } }
    }

    override var text: String? { didSet { setNeedsLayout() } }
    override var font: UIFont? { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        lock.tintColor = HQPalette.label2
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
        lock.contentMode = .center
        lock.isAccessibilityElement = false
        leftViewMode = .unlessEditing
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var lockSize: CGSize { lock.intrinsicContentSize }

    /// The name's width as drawn, capped to what fits beside the lock.
    private func nameWidth(in bounds: CGRect) -> CGFloat {
        let measured = ceil(((text ?? "") as NSString).size(withAttributes: [.font: font ?? HQFont.preferred(.subheadline)]).width)
        return min(measured, bounds.width - 2 * inset - lockSize.width - gap)
    }

    private var lockShown: Bool { showsLock && !isEditing }

    override func leftViewRect(forBounds bounds: CGRect) -> CGRect {
        guard lockShown else { return super.leftViewRect(forBounds: bounds) }
        let size = lockSize
        let x = max(inset, (bounds.width - (size.width + gap + nameWidth(in: bounds))) / 2)
        return CGRect(x: round(x), y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        guard lockShown else { return super.textRect(forBounds: bounds).insetBy(dx: inset, dy: 0) }
        let lockFrame = leftViewRect(forBounds: bounds)
        return CGRect(x: lockFrame.maxX + gap, y: bounds.minY, width: nameWidth(in: bounds), height: bounds.height)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds).insetBy(dx: inset, dy: 0)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        super.placeholderRect(forBounds: bounds).insetBy(dx: inset, dy: 0)
    }
}
