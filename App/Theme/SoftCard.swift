// [soft-cards] The one material of Soft Cards (Theme › Backgrounds › App Background › Soft Cards). Owner 2026-11-12,
// after the first build: "This needs a TON of work to be something we can actually release proudly." The first cards
// were near-solid slabs of the card colour (78 %) that hid the picture they were chosen for, in three makes (a card, a
// lighter plate behind grouped pages' cards, SwiftUI's own material for loose lines), with boxes inside boxes.
//
// The same day: "These need to always match the theme that is currently used … Must be subtle - only to make things more
// legible."
//
// Now every backing is this surface and nothing nests. It is the theme's own page seen through frosted glass, no more:
// - the picture softened behind it (iOS's plain blur, which has no colour of its own; the Desktop Look's bars are made
//   the same way, DesktopFrost.swift), so line drawings and photo detail do not run through words;
// - the theme's page colour over that (the colour Dim lays over the picture, so a card is a little more Dim where the
//   words are), only as dense as this picture needs for the faintest words on it (label 2) to read at 4.5:1
//   (`SoftCard.density`): a calm or dimmed picture gets a card that is barely there, a bright photo in the dark a
//   denser one;
// - a hairline edge in the theme's ink, so a card on a picture of its own tone still has a shape;
// - the grouped cards' corners (`HQShape`).

import SwiftUI
import UIKit

@MainActor enum SoftCard {
    /// The corners of every soft card.
    static var radius: CGFloat { HQShape.radius(26, .card) }
    /// The lightest and the densest a card gets.
    nonisolated static let densityRange = 0.2...0.9
    /// What the faintest words on a card must measure against it (WCAG).
    nonisolated static let contrast = 4.5

    /// A grouped row on a soft card: nothing of its own (the card is behind it), and the ink at 9 % while pressed.
    static let rowClear = UIColor { @Sendable _ in .clear }
    static let rowPressed = UIColor { @Sendable traits in HQPalette.label.resolvedColor(with: traits).withAlphaComponent(0.09) }
    static let edge = UIColor { @Sendable traits in
        HQPalette.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.09 : 0.06)
    }

    /// The theme's page colour at the density this picture needs, for `traits` (Light or Dark, the skin).
    static func tint(_ traits: UITraitCollection) -> UIColor {
        HQPalette.page.resolvedColor(with: traits).withAlphaComponent(CGFloat(density(traits)))
    }

    static func density(_ traits: UITraitCollection) -> Double {
        let dark = traits.userInterfaceStyle == .dark
        let tone = Backdrop.app.picture(for: traits).flatMap { picture in
            BackdropImages.shared.image(picture).map { SoftCardTone.of($0, picture: picture) }
        }
        let ink = HQPalette.label2.resolvedColor(with: traits)
        var alpha: CGFloat = 1
        ink.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        // No picture made yet: the worst one (white in the dark, black in the light).
        return density(picture: tone.map { dark ? $0.bright : $0.dark } ?? (dark ? 1 : 0), dim: Double(Backdrop.app.dim) / 100,
                       page: luminance(HQPalette.page.resolvedColor(with: traits)), card: luminance(HQPalette.page.resolvedColor(with: traits)),
                       ink: luminance(ink.withAlphaComponent(1)), inkAlpha: Double(alpha))
    }

    /// The least density at which words in `ink` (at `inkAlpha` over the card) read at `contrast` on a card of
    /// luminance `card` over a picture whose hardest part for them is `picture`, under Dim's veil of the page colour.
    /// All luminances are linear (0…1); the layers are mixed as the screen mixes them, in sRGB.
    nonisolated static func density(picture: Double, dim: Double, page: Double, card: Double, ink: Double, inkAlpha: Double) -> Double {
        let under = dim * encoded(page) + (1 - dim) * encoded(picture)
        let cardTone = encoded(card), inkTone = encoded(ink)
        var density = densityRange.lowerBound
        while density < densityRange.upperBound {
            let surface = density * cardTone + (1 - density) * under
            let words = inkAlpha * inkTone + (1 - inkAlpha) * surface
            let a = decoded(words) + 0.05, b = decoded(surface) + 0.05
            if max(a, b) / min(a, b) >= contrast { return density }
            density += 0.02
        }
        return densityRange.upperBound
    }

    nonisolated static func encoded(_ linear: Double) -> Double {
        let value = min(max(linear, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    nonisolated static func decoded(_ tone: Double) -> Double {
        let value = min(max(tone, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ color: UIColor) -> Double {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * decoded(Double(r)) + 0.7152 * decoded(Double(g)) + 0.0722 * decoded(Double(b))
    }
}

/// How bright and how dark a picture gets, as a card sees it: the picture drawn small (which evens out fine detail, as
/// the card's blur does), then its brightest and darkest tenths.
nonisolated struct SoftCardTone: Sendable, Equatable {
    var bright: Double
    var dark: Double

    @MainActor private static var known: [BackdropPicture: SoftCardTone] = [:]

    @MainActor static func of(_ image: UIImage, picture: BackdropPicture) -> SoftCardTone {
        if let tone = known[picture] { return tone }
        let tone = image.cgImage.map(measure) ?? SoftCardTone(bright: 1, dark: 0)
        if known.count > 8 { known.removeAll() }
        known[picture] = tone
        return tone
    }

    static func measure(_ image: CGImage) -> SoftCardTone {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return SoftCardTone(bright: 1, dark: 0) }
        var tones: [Double] = []
        tones.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = SoftCard.decoded(Double(pixels[index]) / 255), g = SoftCard.decoded(Double(pixels[index + 1]) / 255)
            let b = SoftCard.decoded(Double(pixels[index + 2]) / 255)
            tones.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        tones.sort()
        let tenth = max(1, tones.count / 10)
        return SoftCardTone(bright: tones.suffix(tenth).reduce(0, +) / Double(tenth), dark: tones.prefix(tenth).reduce(0, +) / Double(tenth))
    }
}

/// The surface itself. `shape` picks its corners; `open` sides run on into a neighbour (no corners, no edge there).
final class SoftCardSurface: UIView {
    enum Shape { case card, capsule }
    struct Sides: OptionSet { let rawValue: Int; static let top = Sides(rawValue: 1); static let bottom = Sides(rawValue: 2) }

    var shape: Shape = .card { didSet { setNeedsLayout() } }
    var open: Sides = [] { didSet { setNeedsLayout() } }

    private let blur = UIVisualEffectView(effect: DesktopFrost.blur())
    private let tint = UIView()
    private let rim = UIView()
    private var watches: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        rim.layer.cornerCurve = .continuous
        rim.isUserInteractionEnabled = false
        for view in [blur, tint, rim] as [UIView] { addSubview(view) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: SoftCardSurface, _) in
            view.paint()
        }
        for name in [Backdrop.didChange, Backdrop.pictureReady, Theme.didChange] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paint() }
            })
        }
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watches.forEach(NotificationCenter.default.removeObserver) }

    private func paint() {
        tint.backgroundColor = SoftCard.tint(traitCollection)
        rim.layer.borderColor = SoftCard.edge.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { paint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = shape == .capsule ? bounds.height / 2 : min(SoftCard.radius, min(bounds.width, bounds.height) / 2)
        var corners: CACornerMask = []
        if !open.contains(.top) { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if !open.contains(.bottom) { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        layer.cornerRadius = radius
        layer.maskedCorners = corners
        blur.frame = bounds
        tint.frame = bounds
        // The edge runs off an open side, where the card's own clipping cuts it.
        let line = 1 / max(traitCollection.displayScale, 2)
        var frame = bounds
        if open.contains(.top) { frame.origin.y -= radius + 2; frame.size.height += radius + 2 }
        if open.contains(.bottom) { frame.size.height += radius + 2 }
        rim.frame = frame
        rim.layer.cornerRadius = radius
        rim.layer.borderWidth = line
    }
}

/// The surface behind a SwiftUI view (`hqPictureBacking`).
struct SoftCardBackground: UIViewRepresentable {
    var capsule = false
    func makeUIView(context: Context) -> SoftCardSurface {
        let surface = SoftCardSurface()
        surface.shape = capsule ? .capsule : .card
        return surface
    }
    func updateUIView(_ surface: SoftCardSurface, context: Context) { surface.shape = capsule ? .capsule : .card }
}
