// [offline] The launch screen (docs/spec/3x-offline.md §3.1), the web app's `src/launch-screen.ts` and
// `launch-screen.css` in UIKit. It draws what `LaunchGate` says and owns no timer: the 96 pt icon centred in the
// window's full bounds (the icon the app wears, `AppIcons.wornPicture`; the system launch screen, Info.plist
// `UILaunchScreen`, is the page colour alone, as it can't know which icon was chosen), so the hand-over from the
// system's screen is only the icon appearing (it scrolls with the words only when they do not fit); an activity indicator 90 pt below centre once the wait is noticeable; a
// caption 118 pt below centre that says what it waits for; after 12 s the usual cause with Try Again and Change Address
// or Sign In. Only dynamic colours, so it follows light and dark live (§3.3).

import UIKit

final class LaunchViewController: UIViewController {
    static let iconSide: CGFloat = 96
    static let spinnerOffset: CGFloat = 90
    static let captionOffset: CGFloat = 118
    static let captionWidth: CGFloat = 300

    var onTryAgain: (() -> Void)?
    var onDifferentGateway: (() -> Void)?
    /// "Change Address or Sign In" needs a gateway to start from.
    var offersDifferentGateway = true { didSet { if isViewLoaded { apply(animated: false) } } }

    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let scroll = UIScrollView()
    private let foot = UIStackView()
    private let caption = UILabel()
    private let tryAgain = UIButton(configuration: .hqProminentGlass())
    private let different = UIButton(configuration: .hqGlass())
    private(set) var shown = LaunchGate.View()
    private var spoken = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = "launch"

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = true
        icon.accessibilityLabel = "Hermes HQ"
        icon.accessibilityTraits = .image
        icon.accessibilityIdentifier = "launch.icon"
        icon.layer.cornerCurve = .continuous
        showIcon()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (self: Self, _) in self.showIcon() }

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.alpha = 0
        spinner.hidesWhenStopped = false
        spinner.color = HQPalette.label2
        spinner.accessibilityIdentifier = "launch.spinner"

        caption.font = HQFont.preferred(.subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = HQPalette.label2
        caption.textAlignment = .center
        caption.numberOfLines = 0           // the storage sentence is long: it wraps whole, the screen scrolls at large sizes
        caption.accessibilityIdentifier = "launch.caption"
        caption.accessibilityTraits = .staticText

        configure(tryAgain, title: OfflineCopy.tryAgain, id: "launch.try-again") { [weak self] in self?.onTryAgain?() }
        tryAgain.tintColor = HQPalette.tint
        configure(different, title: OfflineCopy.differentGateway, id: "launch.different-gateway") { [weak self] in self?.onDifferentGateway?() }

        foot.axis = .vertical
        foot.alignment = .fill
        foot.spacing = 16
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.addArrangedSubview(caption)
        foot.addArrangedSubview(tryAgain)
        foot.addArrangedSubview(different)
        foot.setCustomSpacing(20, after: caption)

        // Everything sits in one scroll view the size of the window (stress round 1): the icon half a window down its
        // content, exactly where the system launch screen drew it, the words and the buttons under it. When they fit
        // nothing scrolls. At the large accessibility text sizes they do not fit, and the whole screen scrolls from
        // any touch on it, the icon moving away with the rest, so the full sentence and both buttons can be reached.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "launch.scroll"
        view.addSubview(scroll)
        scroll.addSubview(icon)
        scroll.addSubview(spinner)
        scroll.addSubview(foot)
        // Half a window of nothing above the icon's centre. A view, not a layout guide: a guide owned by the scroll
        // view stays with its frame, and the content tied to it then never moved (seen while repairing).
        let half = UIView()
        half.isHidden = true
        half.isUserInteractionEnabled = false
        half.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(half)
        let content = scroll.contentLayoutGuide, frame = scroll.frameLayoutGuide

        NSLayoutConstraint.activate([
            // The window's full bounds, not the safe area: where `UIImageRespectsSafeAreaInsets = false` puts the icon.
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            half.topAnchor.constraint(equalTo: content.topAnchor),
            half.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            half.widthAnchor.constraint(equalToConstant: 1),
            half.heightAnchor.constraint(equalTo: frame.heightAnchor, multiplier: 0.5),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: half.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor, constant: Self.spinnerOffset),

            foot.topAnchor.constraint(equalTo: icon.centerYAnchor, constant: Self.captionOffset),
            foot.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            foot.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            foot.widthAnchor.constraint(lessThanOrEqualToConstant: Self.captionWidth),
            foot.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -48),
        ])
        let wide = foot.widthAnchor.constraint(equalToConstant: Self.captionWidth)
        wide.priority = .defaultHigh
        wide.isActive = true
        apply(animated: false)
    }

    /// "LaunchIcon" (already cut to the icon's shape) for the app's own icon; a chosen one is a full square, cut here
    /// as the Home Screen cuts it. Every icon has a light and a dark version, so this runs again when the appearance
    /// changes.
    private func showIcon() {
        let worn = AppIcons.wornPicture(dark: traitCollection.userInterfaceStyle == .dark,
                                        pixels: Int((Self.iconSide * traitCollection.displayScale).rounded(.up)))
        icon.image = worn ?? UIImage(named: "LaunchIcon")
        icon.layer.cornerRadius = worn == nil ? 0 : Self.iconSide * 0.2237
        icon.layer.masksToBounds = worn != nil
    }

    private func configure(_ button: UIButton, title: String, id: String, action: @escaping () -> Void) {
        button.configuration?.title = title
        button.configuration?.buttonSize = .large
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.configuration?.titleAlignment = .center
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes
            // A button's words stop growing at the first accessibility size (as the system's own buttons do): larger,
            // the longest title ("Change Address or Sign In") still wraps to three lines and out of its capsule.
            let chosen = UIApplication.shared.preferredContentSizeCategory
            let size = chosen > .accessibilityMedium ? UIContentSizeCategory.accessibilityMedium : chosen
            next.font = HQFont.preferred(.headline, compatibleWith: UITraitCollection(preferredContentSizeCategory: size))
            return next
        }
        // The capsule is always taller than its words, however they wrap.
        if let title = button.titleLabel {
            button.heightAnchor.constraint(greaterThanOrEqualTo: title.heightAnchor, constant: 24).isActive = true
        }
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    /// The words and buttons end above the home indicator, also at the end of a scroll.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        scroll.contentInset.bottom = view.safeAreaInsets.bottom
        scroll.verticalScrollIndicatorInsets.top = view.safeAreaInsets.top
    }

    /// The gate's next reading.
    func render(_ next: LaunchGate.View) {
        guard next != shown else { return }
        shown = next
        if isViewLoaded { apply(animated: view.window != nil) }
    }

    private func apply(animated: Bool) {
        let showSpinner = shown.spinner && shown.phase == .shown
        if showSpinner, !spinner.isAnimating { spinner.startAnimating() }
        let fade = {
            self.spinner.alpha = showSpinner ? 1 : 0
        }
        if animated { UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: fade) } else { fade() }   // motion-ok: opacity only
        if !showSpinner, !animated { spinner.stopAnimating() }

        let words = shown.phase == .gone ? "" : shown.status
        caption.text = words
        caption.isHidden = words.isEmpty
        let actions = shown.actions && shown.phase == .shown
        tryAgain.isHidden = !actions
        different.isHidden = !actions || !offersDifferentGateway
        // New words start from the top; when they run past the bottom the scroll bar shows for a moment to say so.
        view.layoutIfNeeded()
        let overflows = scroll.contentSize.height + scroll.contentInset.bottom > scroll.bounds.height + 0.5
        if !overflows { scroll.contentOffset = .zero } else if actions { scroll.flashScrollIndicators() }
        // Touches release when the screen starts to leave.
        view.isUserInteractionEnabled = shown.phase == .shown

        // VoiceOver: while only the icon shows the screen is one element, "Hermes HQ"; once there are words the icon
        // is decoration and the caption is read, announced once each time it appears or changes.
        icon.isAccessibilityElement = words.isEmpty
        if words != spoken {
            spoken = words
            if !words.isEmpty, view.window != nil { HQAnnounce.say(words) }
        }
    }

    #if DEBUG
    /// The icon's frame in window coordinates (the pixel check against the system launch screen).
    var iconFrame: CGRect { icon.convert(icon.bounds, to: view) }
    #endif
}
