// desktoplook2: the Desktop Look's LAYOUT (spec 3x-desktoplook §5; the web's v2/v3, phone-ui-desktop.css:139-375,
// owner-approved on web builds 100–105). One place for the desktop's metrics, its press and lift, its section label
// and its outlined box, so every screen draws them alike. Every helper here is only reached when `Theme.isDesktop`;
// with the look off the callers keep their own iOS code path untouched.

import ObjectiveC
import SwiftUI
import UIKit

nonisolated enum DesktopRows {
    /// Bots and Sessions rows, one height (phone-ui-desktop.css:272-275), × UI Scale.
    static var height: CGFloat { HQFont.scaled(60) }
    /// The face: a 32 pt square (the desktop sidebar's).
    static var face: CGFloat { HQFont.scaled(32) }
    /// Face to text.
    static let gap: CGFloat = 10
    /// The page gutter (phone-ui-desktop.css:349).
    static let gutter: CGFloat = 20
    /// [top-bar-gap] Owner 2026-11-09: the extra room the first thing under a tab's bar gets in the Desktop Look on the
    /// iPhone and iPad, where the bar is a frosted band whose edge shows (pills, tiles and rows sat 4–8 pt under it).
    /// The Mac already opens its pages with the iOS look's room (stress test 2026-10-28 round 7); the iOS look's bar is
    /// clear, with nothing to crowd.
    @MainActor static var underBar: CGFloat { Theme.isDesktop && !DeviceWord.isMac ? 8 : 0 }
    /// A pressed row's box: 2 pt in from the row's top and foot, 8 pt in from its sides (phone-ui-desktop.css:330).
    static let pressInset = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    static let radius: CGFloat = 4
    /// The desktop's label (SESSIONS, WORK · 2): 11 pt semibold capitals tracked 0.08 em (phone-ui-desktop.css:74-75).
    static let labelSize: CGFloat = 11
    static let labelTracking: CGFloat = 0.08
}

@MainActor enum DesktopLayout {
    static var on: Bool { Theme.isDesktop }

    /// A list row's background in the look: nothing at rest; pressed or selected, one flat rounded box inset in the
    /// row (its ⋯ included), in the desktop's active-row fill. No iOS full-bleed grey.
    static func rowBackground(_ state: UICellConfigurationState) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        if state.isHighlighted || state.isSelected {
            background.backgroundColor = HQPalette.cellPressed
            background.backgroundInsets = DesktopRows.pressInset
            background.cornerRadius = DesktopRows.radius
        }
        return background
    }

    /// A held row lifted for its menu: flat (no drop shadow), square-cornered, on the editor surface, the box the
    /// press drew. The stroke is drawn by `outlineLift`.
    static func liftParameters(for bounds: CGRect, inset: CGFloat = 8) -> UIPreviewParameters {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = ChatPalette.editor
        let box = bounds.insetBy(dx: inset, dy: 0)
        parameters.visiblePath = UIBezierPath(roundedRect: box, cornerRadius: DesktopRows.radius)
        parameters.shadowPath = UIBezierPath()        // no iOS drop shadow
        return parameters
    }

    /// The lift's outline: a 1 pt stroke on the lifted view while its menu is up (removed with `clearLift`).
    static func outlineLift(_ view: UIView, inset: CGFloat = 8) {
        clearLift(view)
        let stroke = CAShapeLayer()
        stroke.name = liftLayerName
        stroke.path = UIBezierPath(roundedRect: view.bounds.insetBy(dx: inset + 0.5, dy: 0.5), cornerRadius: DesktopRows.radius).cgPath
        stroke.fillColor = nil
        stroke.strokeColor = ChatPalette.strokeSecondary.resolvedColor(with: view.traitCollection).cgColor
        stroke.lineWidth = 1
        stroke.zPosition = 1000
        view.layer.addSublayer(stroke)
    }

    static func clearLift(_ view: UIView) {
        view.layer.sublayers?.filter { $0.name == liftLayerName }.forEach { $0.removeFromSuperlayer() }
    }
    private static let liftLayerName = "hq.desktop.lift"

    /// A glass panel that draws its own Desktop Look (the chat title): ThemeChrome leaves it alone.
    static func keepOwnLook(_ view: UIVisualEffectView) {
        objc_setAssociatedObject(view, ownLookKey, true, .OBJC_ASSOCIATION_RETAIN)
    }
    static func keepsOwnLook(_ view: UIView) -> Bool { (objc_getAssociatedObject(view, ownLookKey) as? Bool) ?? false }
    private static let ownLookKey = malloc(1)!

    /// The label font (UIKit).
    static func labelFont() -> UIFont {
        HQFont.system(ofSize: DesktopRows.labelSize * HQFont.dynamicRatio(nil), weight: .semibold)
    }

    /// Attributes of the desktop's label (UIKit), for bar titles and headers.
    static func labelAttributes(color: UIColor = HQPalette.label2, size: CGFloat = DesktopRows.labelSize) -> [NSAttributedString.Key: Any] {
        let font = HQFont.system(ofSize: size * HQFont.dynamicRatio(nil), weight: .semibold)
        return [.font: font, .foregroundColor: color, .kern: font.pointSize * DesktopRows.labelTracking]
    }
}

// MARK: - SwiftUI

extension View {
    /// The desktop's label: capitals, tracked, semibold, secondary colour. Look off: the view as it is.
    @ViewBuilder func hqDesktopLabel(_ on: Bool = Theme.isDesktop, size: CGFloat = DesktopRows.labelSize,
                                     color: Color = .hqLabel2) -> some View {
        if on {
            self.textCase(.uppercase)
                .font(Font.hqSystem(size: size * HQFont.dynamicRatio(nil), weight: .semibold))
                .tracking(size * HQFont.dynamicRatio(nil) * DesktopRows.labelTracking)
                .foregroundStyle(color)
        } else {
            self
        }
    }

    /// A 4 pt outlined box on the page (the desktop's settings fields and roster sections). Look off: unchanged.
    @ViewBuilder func hqDesktopBox(_ on: Bool = Theme.isDesktop, fill: Color = .hqPage) -> some View {
        if on {
            self.background(fill, in: RoundedRectangle(cornerRadius: DesktopRows.radius))
                .overlay(RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(Color.hqStroke, lineWidth: 1))
        } else {
            self
        }
    }
}

/// A press in the look: the flat rounded inset box over the whole control, no scale, no shadow.
struct DesktopPressStyle: ButtonStyle {
    var inset: EdgeInsets = EdgeInsets(top: 2, leading: -6, bottom: 2, trailing: -6)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: DesktopRows.radius).fill(Color(uiColor: HQPalette.cellPressed)).padding(inset)
                }
            }
    }
}

/// The desktop's outlined button (Bot Info's quick actions, a sheet's secondary button): no fill at rest, a 1 pt
/// stroke, the active-row fill pressed (phone-ui-desktop.css:352-354).
struct DesktopOutlinedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.hqLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Color(uiColor: HQPalette.cellPressed) : Color.clear,
                        in: RoundedRectangle(cornerRadius: DesktopRows.radius))
            .overlay(RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(Color.hqStroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DesktopRows.radius))
    }
}

/// A row's trailing action in the iOS look: a ~28 pt capsule (bordered: grey fill, tint text; prominent: tint fill) drawn
/// inside a 44 pt tall touch target, so the row stays compact and the button stays easy to hit (stress round 1: 34 pt
/// targets were too small).
struct RowActionButtonStyle: ButtonStyle {
    /// How far the 44 pt touch target reaches past a default-size capsule, above and below. A one-line row pulls in
    /// by this much so the target overlaps the row's own padding rather than making the row taller.
    static let targetOverhang: CGFloat = 10
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.font) private var font
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font ?? Font.hq(.subheadline).weight(.semibold))
            .foregroundStyle(prominent ? Color.hqOnTint : Color.hqTintText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(prominent ? AnyShapeStyle(Color.hqTint) : AnyShapeStyle(Color.hqFill3), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.45)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The desktop's primary button: the accent, square-cornered, no glass.
struct DesktopProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.hqOnTint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.hqTint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: DesktopRows.radius))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DesktopRows.radius))
    }
}

extension View {
    /// `.buttonStyle(.glass)` with the look off; the desktop's outlined button with it on.
    @ViewBuilder func hqGlassButtonStyle() -> some View {
        if Theme.isDesktop { self.buttonStyle(DesktopOutlinedButtonStyle()) } else { self.buttonStyle(.glass) }
    }

    /// `.buttonStyle(.bordered)` with the look off; the desktop's outlined button with it on.
    @ViewBuilder func hqBorderedButtonStyle() -> some View {
        // [mac] Stress test 2026-10-28 #55 (round 6): the Mac's one push button in both looks (#50 drew a rounded
        // `.bordered` in the iOS look, which kept iOS's tinted fill and link-blue words).
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle()) }
        else if Theme.isDesktop { self.buttonStyle(DesktopOutlinedButtonStyle()) }
        else { self.buttonStyle(.bordered) }
    }

    /// A small action at a row's trailing edge (Get, Connect, Approve, Add): a small capsule like the App Store's, not a
    /// full-height button (owner 2026-10-16: rows read too big). The look keeps its own outlined button.
    @ViewBuilder func hqRowActionButtonStyle(prominent: Bool = false) -> some View {
        // [mac] Stress test 2026-10-28 #55 (round 6): Get, Connect, Approve as the Mac's push button in both looks.
        if DeviceWord.isMac {
            self.buttonStyle(MacPushButtonStyle(kind: prominent ? .prominent : .plain))
        } else if Theme.isDesktop {
            if prominent { self.buttonStyle(DesktopProminentButtonStyle()) } else { self.buttonStyle(DesktopOutlinedButtonStyle()) }
        } else {
            self.buttonStyle(RowActionButtonStyle(prominent: prominent))
        }
    }

    /// A row that draws nothing behind it (a note standing on the page): in the look its section gets no outline.
    @ViewBuilder func hqDesktopBareRow() -> some View {
        if Theme.isDesktop { self.background(DesktopBareRowMarker()) } else { self }
    }

    /// `.buttonStyle(.borderedProminent)` with the look off; the desktop's accent button with it on.
    @ViewBuilder func hqProminentButtonStyle() -> some View {
        // [mac] Stress test 2026-10-28 #55 (round 6): the Mac's default push button (accent, rounded) in both looks.
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle(kind: .prominent)) }
        else if Theme.isDesktop { self.buttonStyle(DesktopProminentButtonStyle()) } else { self.buttonStyle(.borderedProminent) }
    }

    /// `.buttonStyle(.glassProminent)` with the look off; the desktop's accent button with it on.
    @ViewBuilder func hqGlassProminentButtonStyle() -> some View {
        // [mac] Stress test 2026-10-28 #55 (round 6): the Mac's default push button (accent, rounded) in both looks.
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle(kind: .prominent)) }
        else if Theme.isDesktop { self.buttonStyle(DesktopProminentButtonStyle()) } else { self.buttonStyle(.glassProminent) }
    }

    /// [mac] Stress test 2026-10-28 #55 (round 6): an empty state's or a failure's action (New Task…, Try Again, Show
    /// All). Elsewhere the prominent button it was; on the Mac the plain push button, since it isn't the page's one
    /// default action (Kanban's io New Task… was a white-on-grey capsule that read as switched off).
    @ViewBuilder func hqEmptyActionButtonStyle(glass: Bool = false) -> some View {
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle()) }
        else if glass { self.hqGlassProminentButtonStyle() } else { self.hqProminentButtonStyle() }
    }
}

/// The desktop's segmented strip (phone-ui-desktop.css, segmented): one 4 pt outlined box, 1 pt dividers, the chosen
/// segment on the active-row fill. SwiftUI's segmented Picker draws iOS 26's own pill whatever its images, so a
/// screen that wants the strip in the look shows this in its place.
struct DesktopSegmentStrip<Value: Hashable>: View {
    var options: [(title: String, value: Value)]
    @Binding var selection: Value
    /// Each segment at least as wide as its whole label (for `ViewThatFits`, which then falls back to rows).
    var wholeLabels = false
    /// A tick when a tap changes the segment, as iOS-look segments (`WholeLabelSegmentsControl`) give. False where the
    /// caller plays its own (Artifacts' filter), so one pick never taps twice.
    var ticks = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Rectangle().fill(Color.hqStroke).frame(width: 1) }
                let first = index == 0, last = index == options.count - 1, radius = DesktopRows.radius
                Button {
                    if ticks, selection != option.value { Haptics.play(.selection) }
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Font.hq(.footnote).weight(selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Color.hqLabel : Color.hqLabel2)
                        .lineLimit(1)
                        .fixedSize(horizontal: wholeLabels, vertical: false)
                        // [page-tabs] At least iOS's own room beside a whole label (about 19 pt a segment): 14 put Bot
                        // Info's five tabs in a pull-down one size above the standard text.
                        .padding(.horizontal, wholeLabels ? 10 : 0)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        // The fill's own corners (the strip isn't clipped: a clip would cut the taller hit area below).
                        .background(selection == option.value ? Color(uiColor: HQPalette.cellPressed) : Color.clear,
                                    in: UnevenRoundedRectangle(topLeadingRadius: first ? radius : 0, bottomLeadingRadius: first ? radius : 0,
                                                               bottomTrailingRadius: last ? radius : 0, topTrailingRadius: last ? radius : 0))
                        // UX #160: drawn 32 pt tall, touched over 44 pt.
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -6)
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .overlay(RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(Color.hqStroke, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A SwiftUI section header (scripts/desktoplook2-headers.py wraps every one): its content unchanged with the look
/// off; the desktop's label with it on.
struct HQSectionLabel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #52: in the iOS look a header was the same 15 pt grey as the footer above it,
        // 8 pt away, so a page read as one grey paragraph. On the Mac it is the header token, with room above it.
        if Theme.isDesktop {
            content.hqDesktopLabel()
        } else {
            content.font(MacType.sectionHeaderFont).foregroundStyle(Color.hqLabel2).padding(.top, MacInset.headerGap)
        }
        #else
        // [ui-sizing] iOS's own header at the UI Scale in use, not the page's scaled body (`HQListText`).
        content.hqDesktopLabel().font(HQListText.header)
        #endif
    }
}

// MARK: - UIKit buttons

extension UIButton.Configuration {
    /// `.glass()` with the look off; the desktop's outlined button with it on (made when the button is).
    @MainActor static func hqGlass() -> UIButton.Configuration {
        guard Theme.isDesktop else { return .glass() }
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = HQPalette.label
        config.cornerStyle = .fixed
        config.background.cornerRadius = DesktopRows.radius
        config.background.strokeColor = ChatPalette.strokeSecondary
        config.background.strokeWidth = 1
        config.background.backgroundColor = .clear
        return config
    }

    /// [mac] Stress test 2026-10-28 #50: a worded button (Copy Chat Info, Try Again, Show All) as a Mac push button in the
    /// iOS look: a grey rounded rectangle, not a glass capsule. The Desktop Look keeps its outlined button; the iPhone
    /// its glass (`hqGlass`). Icon-only glass circles (photo arrows, Talk) stay `hqGlass`.
    /// [mac] Stress test 2026-10-28 #55 (round 6): on the Mac, in both looks, the Mac's one push button (`MacPush`).
    @MainActor static func hqPush() -> UIButton.Configuration {
        guard DeviceWord.isMac else { return hqGlass() }
        return MacPush.configuration()
    }

    /// [mac] Stress test 2026-10-28 #55 (round 6): the Mac's plain push button; elsewhere `other`, as a capsule when
    /// `capsule` (a Try Again or Choose Folder… under an empty state).
    @MainActor static func hqMacPush(or other: UIButton.Configuration, capsule: Bool = false) -> UIButton.Configuration {
        if DeviceWord.isMac { return MacPush.configuration() }
        var config = other
        if capsule { config.cornerStyle = .capsule }
        return config
    }

    /// `.prominentGlass()` with the look off; the desktop's accent button with it on.
    @MainActor static func hqProminentGlass() -> UIButton.Configuration {
        guard Theme.isDesktop else { return .prominentGlass() }
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = HQPalette.tint
        config.baseForegroundColor = HQPalette.onTint
        config.cornerStyle = .fixed
        config.background.cornerRadius = DesktopRows.radius
        return config
    }
}

// MARK: - [desktoplook3] No glass anywhere in the look (owner: "the Liquid Glass on the desktop look throws off the look
// a lot"). Each helper is the iOS 26 glass call with the look off, and a flat, solid, outlined desktop piece with it on.

extension View {
    /// `.glassEffect(.regular, in: shape)` with the look off; the editor surface with a 1 pt outline, 4 pt corners, on.
    @ViewBuilder func hqGlassEffect<S: Shape>(in shape: S) -> some View {
        if Theme.isDesktop {
            self.background(Color(uiColor: ChatPalette.editor), in: RoundedRectangle(cornerRadius: DesktopRows.radius))
                .overlay(RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(Color.hqStroke, lineWidth: 1))
        } else {
            self.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// [desktop-composer] The composer's glass (Theme's Text Box preview), tinted `tint` when given: Liquid Glass in
    /// both looks unless Text Box › Desktop is picked, as the chat's own bar (`ComposerView.holdsOwnGlass`).
    @ViewBuilder func hqComposerGlass<S: Shape>(tint: Color? = nil, in shape: S) -> some View {
        if Theme.boxComposer {
            self.background(Color(uiColor: ChatPalette.editor), in: shape)
        } else if let tint {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// [glass-bubbles] A chat bubble on the Theme page: Liquid Glass tinted `glass` (`GlassBubbles`), or filled `solid`
    /// when that is nil (the switch off, Reduce Transparency, the Desktop Look).
    @ViewBuilder func hqChatBubble<S: Shape>(_ glass: Color?, solid: Color, in shape: S) -> some View {
        if let glass, !Theme.isDesktop {
            self.glassEffect(.regular.tint(glass), in: shape)
        } else {
            self.background(shape.fill(solid))
        }
    }
}

extension View {
    /// [glass] A pick standing on a glass sheet (New Job's bots, templates and frequency chips; owner 2026-10-31: "as much
    /// that is inside of it as possible should be liquid glass too"): interactive Liquid Glass with the look off, the
    /// picked one tinted and ringed in the tint, or (`prominent`, a chip) the tint itself. One glass whatever the state,
    /// so a pick changes its tint rather than its view. With the look on, nothing: the caller draws the desktop's piece.
    func hqPickGlass<S: InsettableShape>(_ selected: Bool, in shape: S, prominent: Bool = false) -> some View {
        modifier(PickGlass(selected: selected, shape: shape, prominent: prominent))
    }

    /// A row of `hqPickGlass` picks in one glass container: glass can't sample glass, so without it a pick lenses its
    /// tinted neighbour into a smear along its edge. Spacing 0: the picks never melt into each other.
    @ViewBuilder func hqPickGlassRow() -> some View {
        modifier(PickGlassRow())
    }

    /// [Mac UI check 2026-11-13] Opt-in, for a row of chips on the Mac (Tasks' views, New Job's chips): its picks are
    /// drawn as solid pills (the chosen one the tint, the others the card's colour with a hairline) instead of live
    /// glass. Owner: "What is this bleed over from Today to Bots?": in one glass container the unchosen chips' glass
    /// took the chosen chip's solid blue into its rim (a blue "(" on Upcoming, an arc along Bots' top once the row
    /// wrapped). Pills that aren't glass can't lens a neighbour.
    func hqFlatPicks(_ flat: Bool = true) -> some View { environment(\.hqFlatPicks, flat) }
}

private struct FlatPicksKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// `hqFlatPicks`.
    var hqFlatPicks: Bool {
        get { self[FlatPicksKey.self] }
        set { self[FlatPicksKey.self] = newValue }
    }
}

/// `hqPickGlassRow`'s container (none in the Desktop Look, or with flat picks).
private struct PickGlassRow: ViewModifier {
    @Environment(\.hqFlatPicks) private var flat
    @ViewBuilder func body(content: Content) -> some View {
        if Theme.isDesktop || flat { content } else { GlassEffectContainer(spacing: 0) { content } }
    }
}

/// A segmented choice: iOS 26's segmented Picker with the look off; the desktop's outlined strip with it on (SwiftUI's
/// segmented Picker draws its own glass pill whatever images UIKit is given).
struct HQSegmentedPicker<Value: Hashable>: View {
    var label: String
    var options: [(title: String, value: Value)]
    @Binding var selection: Value
    /// A tick on a new pick, whichever of the three controls draws it. False where the binding plays its own.
    var ticks: Bool
    /// [Mac UI check 2026-11-13] The desktop strip's segments each as wide as their whole label with room beside it:
    /// set where the picker is `fixedSize()` beside a row's name (it drew its labels touching, with no padding).
    var wholeLabels: Bool

    init(_ label: String, options: [(title: String, value: Value)], selection: Binding<Value>, ticks: Bool = true, wholeLabels: Bool = false) {
        self.label = label
        self.options = options
        _selection = selection
        self.ticks = ticks
        self.wholeLabels = wholeLabels
    }

    /// The system segments' binding, with the tick the other two controls play themselves.
    private var ticking: Binding<Value> {
        Binding(get: { selection }, set: { next in
            if ticks, next != selection { Haptics.play(.selection) }
            selection = next
        })
    }

    var body: some View {
        let _ = Theme.touch()         // follows a live toggle of the look
        if Theme.isDesktop {
            DesktopSegmentStrip(options: options, selection: $selection, wholeLabels: wholeLabels, ticks: ticks)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
        } else if HQFont.scale != 1 {
            // [ui-sizing 2026-11-09] At a UI Scale, UIKit's segments (`WholeLabelSegments`), whose titles follow it: iOS 26's
            // SwiftUI segmented Picker keeps its 13 pt titles whatever font it is given (Chat Bubbles' Style, Marketplace).
            WholeLabelSegments(titles: options.map(\.title),
                               selected: Binding(get: { options.firstIndex { $0.value == selection } ?? 0 },
                                                 set: { if options.indices.contains($0) { selection = options[$0].value } }),
                               ticks: ticks)
                .frame(height: HQFont.scaled(32))
                .accessibilityLabel(label)
        } else {
            Picker(label, selection: ticking) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.title).tag(option.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// `hqPickGlass`'s glass.
private struct PickGlass<S: InsettableShape>: ViewModifier {
    var selected: Bool
    var shape: S
    var prominent: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hqFlatPicks) private var flat

    @ViewBuilder func body(content: Content) -> some View {
        if Theme.isDesktop {
            content
        } else if flat {
            // `hqFlatPicks`: the same pill, drawn solid.
            let ink = prominent && scheme == .dark ? Color.hqTint.mix(with: .black, by: 0.3) : Color.hqTint
            let fill: Color = selected ? (prominent ? ink : Color.hqTint.opacity(0.16)) : Color(uiColor: HQPalette.card)
            content
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(selected ? (prominent ? Color.clear : Color.hqTint) : Color.hqStroke,
                                            lineWidth: selected ? (prominent ? 0 : 2) : 1))
        } else {
            // In the dark the glass lifts the tint, and white words on a chosen chip read 3.3:1; a third darker, 7.5:1.
            let ink = prominent && scheme == .dark ? Color.hqTint.mix(with: .black, by: 0.3) : Color.hqTint
            let tint: Color? = selected ? (prominent ? ink : Color.hqTint.opacity(0.16)) : nil
            // The ring rides on the content, under the glass's own layer: an overlay after it vanished in a container.
            content.overlay(shape.strokeBorder(Color.hqTint, lineWidth: selected && !prominent ? 2 : 0))
                .glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
        }
    }
}
