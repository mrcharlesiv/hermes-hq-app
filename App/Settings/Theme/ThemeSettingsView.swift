// desktoplook: Settings › Appearance › Theme (spec 3x-desktoplook §9). Desktop Look, its two options (shown only
// while it is on), the desktop theme installer and the skin grid; the iOS look puts the grid first and the installer
// last (UX study #60). Wording is the web app's except where the study chose plainer words.
// [page-tabs] Owner 2026-11-01: the page was "getting kind of long and feels chaotic". Four tabs under the bar:
// Themes (the grid, then the desktop app's themes), Chats (Chat Bubbles), Backgrounds (App Background, Chat Background)
// and Look (Desktop Look, High Contrast, UI Scale). The Desktop Look has no Chats or Backgrounds tab: it keeps its own
// square boxes and plain pages.
// [look-in-themes] Owner 2026-11-01: "I want the desktop look toggle to be in the theme tab, not its own tab." No Look
// tab: the Desktop Look switch heads Themes, above the grid; High Contrast and UI Scale follow the grid. The Desktop
// Look then has one tab, so it shows no strip.
// [theme-pages] Owner 2026-11-03: the tabs were "a duct tape type solution". No tabs: Chat Bubbles and Backgrounds are
// rows of their own under Settings › Appearance, beside Theme, each opening its own page (`ChatBubblesSettings`,
// `BackgroundsSettings`). The Theme page is the look, the themes and the desktop app's themes.

import SwiftUI
import UIKit

final class ThemeSettingsController: UIHostingController<HQScaledRoot<ThemeSettingsView>> {
    init(services: (any AppServices)?) {
        super.init(rootView: HQScaledRoot(ThemeSettingsView(installer: DesktopThemeInstallerModel(services: services))))
        title = "Theme"
        navigationItem.largeTitleDisplayMode = .never
        view.accessibilityIdentifier = "settings.theme"
        view.backgroundColor = HQPalette.page
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// [backdrop] Opens App Background or Chat Background over Backgrounds.
@MainActor final class BackgroundOpener {
    weak var host: UIViewController?

    func open(_ place: Backdrop.Place) {
        guard let navigation = host?.navigationController else { return }
        let page = BackgroundPageController.make(place)
        page.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(page, animated: true)
    }
}

struct ThemeSettingsView: View {
    @State var installer: DesktopThemeInstallerModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    /// The look was just flipped by its own switch: the other look's page opens on that switch, not at the top, as
    /// the grid above it is about a screen tall (UX study #110: no long scroll back to the switch just used).
    @State private var flippedHere = false
    private var theme: Theme { Theme.shared }
    private static let lookRow = "theme.lookRow"
    private static let chatsRow = "theme.desktopChats"
    private static let densityRow = "theme.densityRow"

    static var lookNote: String { "Draws Hermes HQ like the Hermes desktop app: your theme’s own colours on every screen, square corners and solid bars instead of glass. \(DeviceWord.onlyHere)" }
    static let contrastNote = "Sets your messages, boxes, lines and secondary text further apart from the page, in your theme’s own colours. For themes that look flat."
    /// [density] Both looks on the iPhone and iPad too (it was the Desktop Look's only, the iOS look staying at 100 %).
    static var scaleNote: String { DeviceWord.isMac ? macScaleNote : "Makes text, faces and rows larger or smaller, in both looks, on top of the text size set in \(DeviceWord.settingsApp). \(DeviceWord.onlyHere)" }
    /// [density] The iOS look's Density and UI Scale share one group, so its footer names each.
    static var densityNote: String {
        let scale = DeviceWord.isMac
            ? "UI Scale makes text, faces and rows larger or smaller, in both looks. View › Make Text Bigger (⌘+) and Make Text Smaller (⌘−) change it too. Set on this Mac only."
            : "UI Scale makes text, faces and rows larger or smaller, in both looks, on top of the text size set in \(DeviceWord.settingsApp). \(DeviceWord.onlyHere)"
        // [mac] The Mac's bots are in the sidebar, and its rows have one line of preview whatever the density.
        let compact = DeviceWord.isMac
            ? "Compact fits more in the sidebar's bots and on the Sessions page: smaller faces and shorter rows."
            : "Compact fits more on the Bots and Sessions pages: smaller faces, shorter rows and one line of preview."
        return "\(compact) \(scale)"
    }
    /// [mac] The Mac has no text size setting for this app, so UI Scale is its text size, in both looks.
    static let macScaleNote = "Makes text, faces and rows larger or smaller, in both looks. View › Make Text Bigger (⌘+) and Make Text Smaller (⌘−) change it too. Set on this Mac only."
    // UX study #70: plain words for "Desktop palettes only. The selected mode is applied on top."
    static let gridNote = "The same themes as the Hermes desktop app. Light or Dark (set in Appearance) applies on top."

    var body: some View {
        let state = theme.state
        ScrollViewReader { proxy in
            page(state)
                .onChange(of: state.desktopLook) {
                    guard flippedHere else { return }
                    flippedHere = false
                    // The other look's page is a new scroll view: it lays out first, then moves to the switch.
                    Task { @MainActor in proxy.scrollTo(Self.lookRow, anchor: .center) }
                }
                #if DEBUG
                .task {
                    // [desktop-corners] -HQDebugThemeChats YES: the Desktop Look's Corners and Text Box in view (screenshots).
                    // [density] -HQDebugThemeDensity YES: the iOS look's Density and UI Scale in view.
                    let row = UserDefaults.standard.bool(forKey: "HQDebugThemeChats") ? Self.chatsRow
                        : UserDefaults.standard.bool(forKey: "HQDebugThemeDensity") ? Self.densityRow : nil
                    guard let row else { return }
                    try? await Task.sleep(for: .seconds(1))
                    proxy.scrollTo(row, anchor: .center)
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("HQDebugFlipLook"))) { _ in
                    flippedHere = true
                    theme.setDesktopLook(!theme.state.desktopLook)
                }
                #endif
        }
    }

    private func page(_ state: ThemeState) -> some View {
        Group {
            if state.desktopLook {
                // The Desktop Look's page: plain rows on the page colour, each group in a 4 pt outlined box
                // (phone-ui-desktop.css:139-148). Not a List: iOS's grouped cards keep their own round corners.
                ScrollView {
                    // UX #118: no "Theme" label over the grid, under a bar already titled Theme. A flip opens this page
                    // on its switch (`flippedHere`).
                    VStack(alignment: .leading, spacing: 22) {
                        DesktopGroup(footer: Self.lookNote) { lookSwitch(state) }
                        VStack(alignment: .leading, spacing: 8) {
                            grid(state)
                            gridFooter(state).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
                        DesktopGroup(footer: contrastFooter(state)) { contrastSwitch(state) }
                        // [desktop-corners] [desktop-composer] Owner 2026-11-08: the look's own Corners for messages
                        // and the text box, and which text box it draws.
                        DesktopGroup(footer: Self.desktopChatsNote) { desktopChats(state) }
                            .id(Self.chatsRow)
                        // [chat-soft-edge] No Top Edge here: this look's tabs have their own backing and chats are
                        // always soft, so the choice changed nothing.
                        DesktopGroup(footer: Self.scaleNote) { scalePicker(state) }
                        DesktopGroup(footer: nil) { DesktopThemeRows(model: installer) }
                    }
                    // [mac] Stress test 2026-10-28 round 6: the Mac form's readable width and inset (`hqMacForm`), as on
                    // every other Settings page; the grid spanned the whole pane.
                    .padding(.horizontal, DeviceWord.isMac ? 0 : HQShape.gutter(16))
                    .padding(.top, DeviceWord.isMac ? 0 : 16)
                    .padding(.bottom, 16)
                }
                .hqMacForm(settings: true)
                .font(Font.hq(.body))
            } else {
                // UX study #60: the page's main job, the grid, comes first; the desktop app's themes go last, under
                // their own header. UX #118: the grid has no header; the bar's title already says Theme.
                List { Group {
                    // [look-in-themes] The Desktop Look switch heads the page: the look first, then its colours.
                    if ThemeFeature.desktopLook {
                        Section {
                            lookSwitch(state)
                        } footer: { HQSectionFooter {
                            Text(Self.lookNote)
                        } }
                    }
                    Section {
                        grid(state)
                            .padding(.bottom, 4)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } footer: { HQSectionFooter {
                        gridFooter(state)
                    } }
                    if TopEdgeStyle.offered {
                        Section {
                            topEdgePicker(state)
                        } footer: { HQSectionFooter {
                            Text(Self.topEdgeNote(state))
                        } }
                    }
                    // [density] How much fits: Density, then UI Scale (the Mac's text size; on the iPhone and iPad on top of
                    // iOS's), in this look too.
                    Section {
                        densityPicker(state)
                        scalePicker(state)
                    } footer: { HQSectionFooter {
                        Text(Self.densityNote)
                    } }
                    Section {
                        DesktopThemeRows(model: installer)
                    } header: { HQSectionLabel {
                        Text("Hermes Desktop App")
                    } }
                }.hqMacSettingsRowInsets() }
                .hqMacForm(settings: true)   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
                .hqGroupedPage()   // [desktoplook] the page follows the skin
                .listStyle(.insetGrouped)
            }
        }
        // The look's page is drawn by hand on the page colour; the iOS look is an ordinary grouped Settings page
        // (iOS's cards on the grouped page, which follows the skin like every other Settings page).
        .background(state.desktopLook ? Color.hqPage : Color.clear)
        // [compact] The body font is the look's page only: on the List it also made iOS's footers and headers body-sized.
        .onAppear { installer.refresh() }
    }

    static var desktopChatsNote: String {
        ThemeState.textBoxIsFixed ? "How round your messages and the message box are. 4 pt is the desktop app’s."
            : "How round your messages and the text box are. 4 pt is the desktop app’s. Liquid Glass is the \(DeviceWord.name)’s own text box, rounded to match; Desktop is the desktop app’s flat box."
    }

    /// [desktop-corners] [desktop-composer] Corners (with a preview of a reply, your message and the text box) and
    /// Text Box.
    private func desktopChats(_ state: ThemeState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            BubbleCornersRow(stored: state.desktopCorners, style: .solid, composer: state.boxComposer ? .box : .glass) { points in
                theme.setBubbleCorners(points)
            }
            // [mac] The Mac keeps its own message box: no Text Box choice there.
            if !ThemeState.textBoxIsFixed { textBoxPicker(state) }
        }
    }

    @ViewBuilder private func textBoxPicker(_ state: ThemeState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(Color.hqStroke).frame(height: 1).padding(.horizontal, DeviceWord.isMac ? -MacInset.side : -14)
            VStack(alignment: .leading, spacing: 10) {
                Text("Text Box").foregroundStyle(Color.hqLabel).fixedSize()   // [ui-sizing] whole beside its segments
                HQSegmentedPicker("Text Box", options: [("Liquid Glass", DesktopComposer.glass), ("Desktop", DesktopComposer.box)],
                                  selection: Binding(get: { state.desktopComposer }, set: { next in
                                      guard next != state.desktopComposer else { return }
                                      Haptics.play(.selection)
                                      theme.setDesktopComposer(next)
                                      AppLog.trace("settings", "desktop text box \(next.rawValue)")
                                  }), ticks: false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("theme.desktopComposer")
        }
    }

    private func lookSwitch(_ state: ThemeState) -> some View {
        Toggle(isOn: Binding(get: { state.desktopLook }, set: { on in
            Haptics.play(.selection)
            flippedHere = true
            theme.setDesktopLook(on)
        })) {
            Text("Desktop Look").foregroundStyle(Color.hqLabel)
        }
        .tint(state.desktopLook ? Color.hqTintText : nil)
        .accessibilityIdentifier("theme.desktopLook")
        .id(Self.lookRow)
    }

    /// [a11y] iOS Increase Contrast (the debug override too) turns High Contrast on: the switch shows it, and is held.
    private var increaseContrast: Bool { systemContrast == .increased || HQAccessibility.overrides.contrast }

    private func contrastSwitch(_ state: ThemeState) -> some View {
        Toggle(isOn: Binding(get: { ThemeContrast.switchOn(state, increaseContrast: increaseContrast) }, set: { on in
            Haptics.play(.selection)
            theme.setHighContrast(on)
        })) {
            Text("High Contrast").foregroundStyle(Color.hqLabel)
        }
        .tint(Color.hqTintText)
        .disabled(increaseContrast)
        .accessibilityIdentifier("theme.highContrast")
    }

    private func contrastFooter(_ state: ThemeState) -> String {
        [Self.contrastNote, ThemeContrast.switchNote(state, increaseContrast: increaseContrast)].compactMap { $0 }.joined(separator: " ")
    }

    private func scalePicker(_ state: ThemeState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UI Scale").foregroundStyle(Color.hqLabel)
            ScaleSegments(selected: state.uiScalePercent) { percent in
                Haptics.play(.selection)
                theme.setUIScale(percent)
            }
        }
        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
    }

    /// [density] Standard or Compact (the iOS look; the Desktop Look keeps its own rows).
    private func densityPicker(_ state: ThemeState) -> some View {
        HStack(spacing: 12) {
            Text("Density").foregroundStyle(Color.hqLabel).fixedSize()   // [ui-sizing] whole beside its segments
            Spacer(minLength: 8)
            HQSegmentedPicker("Density", options: [("Standard", ListDensity.standard), ("Compact", ListDensity.compact)],
                              selection: Binding(get: { state.density }, set: { next in
                                  guard next != state.density else { return }
                                  Haptics.play(.selection)
                                  theme.setDensity(next)
                                  AppLog.trace("settings", "density \(next.rawValue)")
                              }), ticks: false)
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.density")
        .id(Self.densityRow)
    }

    /// [top-edge] Soft or Hard: how rows meet the top bar where they scroll under it.
    private func topEdgePicker(_ state: ThemeState) -> some View {
        HStack(spacing: 12) {
            Text("Top Edge").foregroundStyle(Color.hqLabel).fixedSize()   // [ui-sizing] whole beside its segments
            Spacer(minLength: 8)
            HQSegmentedPicker("Top Edge", options: [("Soft", TopEdge.soft), ("Hard", TopEdge.hard)],
                              selection: Binding(get: { state.topEdge }, set: { next in
                                  guard next != state.topEdge else { return }
                                  Haptics.play(.selection)
                                  theme.setTopEdge(next)
                                  AppLog.trace("settings", "top edge \(next.rawValue)")
                              }), ticks: false)
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.topEdge")
    }

    static func topEdgeNote(_ state: ThemeState) -> String {
        "Where rows scroll under the top of every tab. Chats always fade softly. Soft blurs them out gradually. Hard is a frosted band with a straight bottom edge."
    }

    private func grid(_ state: ThemeState) -> some View {
        SkinGrid(selected: state.skinID, dark: scheme == .dark, oneColumn: typeSize.isAccessibilitySize) { id in
            Haptics.play(.selection)
            theme.pick(skin: id)
        }
    }

    private func gridFooter(_ state: ThemeState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.gridNote)
            if state.skin.hasOneLook {
                Text("\(state.skin.label) has one look, so Light and Dark draw the same.")
                    .accessibilityIdentifier("theme.oneLookNote")
            }
            if let note = ThemeContrast.skinGridNote(state, increaseContrast: increaseContrast) {
                Text(note).accessibilityIdentifier("theme.contrastNote")
            }
        }
    }
}

/// [theme-pages] Settings › Appearance › Chat Bubbles: the iOS look's message corners and style, on a page of its own
/// (it was the Theme page's Chats tab).
enum ChatBubblesSettings {
    static func make() -> UIViewController {
        let page = SettingsPageController(title: "Chat Bubbles", ChatBubblesSettingsView())
        page.view.accessibilityIdentifier = "settings.chat-bubbles"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct ChatBubblesSettingsView: View {
    private var theme: Theme { Theme.shared }

    static var note: String {
        GlassBubbles.offered
            ? "How round the corners of messages in chats are, and how they’re filled: Solid, Liquid Glass in your theme’s colours, or Tinted with the colours of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Desktop Look has its own Corners, in Theme. \(DeviceWord.onlyHere)"
            : "How round the corners of messages in chats are, and whether they’re Tinted with the colours of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Desktop Look has its own Corners, in Theme. \(DeviceWord.onlyHere)"
    }
    /// [bubbles-note] Owner 2026-11-10 (design pick 23): where the three styles are offered, the note follows the
    /// choice: one line about the style picked, then the rest in three short sentences (it explained all three at
    /// once, in seven lines).
    static func styleLine(_ style: BubbleStyle) -> String {
        switch style {
        case .glass: "Glass: Liquid Glass in your theme’s colours."
        case .tinted: "Tinted: the colours of your Chat Background."
        default: "Solid: filled with your theme’s colours."
        }
    }
    static var shortNote: String {
        "12 pt corners are the standard. With Reduce Transparency on, messages stay solid. The Desktop Look has its own Corners, in Theme. \(DeviceWord.onlyHere)"
    }

    /// [message-colour] What Colour changes, and what Theme means in its row.
    static var colourNote: String {
        // [bot-colour] The face choice, and where a bot's own colour is.
        let faces = "Bot’s Face gives each bot’s chat the colour of its face. A bot can have its own colour in Bot Info › Settings."
        return DeviceWord.isMac
            ? "Colour is for your own messages and the row chosen in the sidebar. Theme keeps your theme’s colour. \(faces)"
            : "Colour is for your own messages. Theme keeps your theme’s colour. \(faces)"
    }

    /// [tinted-bubbles] Tinted picked with no Chat Background: it has no colours to take.
    static let tintedNeedsBackground = "Tinted takes its colours from your Chat Background. Choose one in Settings › Backgrounds; until then, messages are solid."

    var body: some View {
        let state = theme.state
        // UX #118: no "Chat Bubbles" header, under a bar already titled Chat Bubbles.
        List { Group {
            Section {
                BubbleCornersRow(stored: state.bubbleCorners, style: bubbleStyle(state)) { points in theme.setBubbleCorners(points) }
                    .hqRowPadding(4)
                bubbleStylePicker(state)
                // [message-colour] Owner 2026-11-11: your own messages in a colour of your choosing.
                ColourSwatchRow(title: "Colour", value: state.messageColour.title, state: state,
                                swatches: MessageColour.offered.map { ColourSwatch($0) },
                                picked: state.messageColour.swatchID, custom: state.messageColour.customHex,
                                identifier: "theme.messageColour") { swatch in
                    setColour(MessageColour(stored: swatch.id))
                } pickCustom: { hex in
                    setColour(.custom(hex))
                }
                .hqRowPadding(4)
            } footer: { HQSectionFooter {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.colourNote).accessibilityIdentifier("theme.messageColourNote")
                    if GlassBubbles.offered {
                        Text(Self.styleLine(bubbleStyle(state))).foregroundStyle(Color.hqLabel).accessibilityIdentifier("theme.bubbleStyleLine")
                        Text(Self.shortNote)
                    } else {
                        Text(Self.note)
                    }
                    if bubbleStyle(state) == .tinted && Backdrop.chats.drawn == nil {
                        Text(Self.tintedNeedsBackground).accessibilityIdentifier("theme.tintedNeedsBackground")
                    }
                }
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
    }

    /// [message-colour] Chat Bubbles › Colour.
    private func setColour(_ colour: MessageColour) {
        guard colour != theme.state.messageColour else { return }
        theme.setMessageColour(colour)
        AppLog.trace("settings", "message colour \(colour.stored ?? "theme")")
    }

    /// [glass-bubbles] [tinted-bubbles] The style the chats draw: Glass reads as Solid where it isn't offered (the Mac).
    private func bubbleStyle(_ state: ThemeState) -> BubbleStyle { BubbleStyles.shown(state.bubbleStyle) }

    /// [glass-bubbles] [tinted-bubbles] Solid, Glass or Tinted: segments on the iPhone; on the Mac, which has no glass,
    /// a Tinted switch (stress test 2026-10-28 #73: no two-choice segments there).
    @ViewBuilder private func bubbleStylePicker(_ state: ThemeState) -> some View {
        let style = bubbleStyle(state)
        let pick = { (next: BubbleStyle) in
            guard next != style else { return }
            Haptics.play(.selection)
            theme.setBubbleStyle(next)
            AppLog.trace("settings", "bubble style \(next.rawValue)")
        }
        if GlassBubbles.offered {
            HStack(spacing: 12) {
                Text("Style").foregroundStyle(Color.hqLabel).fixedSize()   // [ui-sizing] whole beside its segments (it wrapped "Styl / e" at 150 %)
                Spacer(minLength: 8)
                HQSegmentedPicker("Style", options: BubbleStyles.offered.map { ($0.title, $0) },
                                  selection: Binding(get: { style }, set: { pick($0) }), ticks: false)
                .labelsHidden()
                .fixedSize()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("theme.bubbleStyle")
        } else {
            Toggle("Tinted", isOn: Binding(get: { style == .tinted }, set: { pick($0 ? .tinted : .solid) }))
                .tint(Color.hqTint)
                .accessibilityIdentifier("theme.tintedBubbles")
        }
    }
}

/// Theme › Chat Bubbles: a few bubbles drawn as the chat draws them, and a slider for their corner. The preview follows
/// the drag; the chats only change when the slider is let go (each change lays every open chat out again).
private struct BubbleCornersRow: View {
    var stored: Int
    var style: BubbleStyle
    /// [desktop-corners] Set in the Desktop Look: its preview, with the text box this look draws.
    var composer: DesktopComposer?
    var commit: (Int) -> Void
    @State private var draft: Double?
    @State private var dragging = false

    private static let range = ThemeState.bubbleCornerRange

    var body: some View {
        let points = Int((draft ?? Double(stored)).rounded())
        VStack(alignment: .leading, spacing: 12) {
            // [tinted-bubbles] On the Chat Background where there is one: the styles are told apart on it.
            if let composer {
                DesktopCornersPreview(radius: CGFloat(points), composer: composer)
            } else {
                ChatGroundPanel { ground in BubbleCornersPreview(radius: CGFloat(points), style: style, ground: ground) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Corners").foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text("\(points) pt").monospacedDigit().foregroundStyle(Color.hqLabel2)
            }
            .accessibilityHidden(true)   // the slider says both
            Slider(value: Binding(get: { draft ?? Double(stored) }, set: { value in
                if Int(value.rounded()) != points { Haptics.play(.selection) }
                draft = value
                // VoiceOver's swipes and the Mac's arrow keys move it without a drag: those apply at once.
                if !dragging { finish() }
            // No `step`: iOS 26 draws a dot for every step under the track (25 here). The value is rounded instead.
            }), in: Double(Self.range.lowerBound)...Double(Self.range.upperBound)) {
                Text("Bubble Corners")
            } minimumValueLabel: {
                Image(systemName: "square").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "capsule").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            } onEditingChanged: { editing in
                dragging = editing
                if !editing { finish() }
            }
            // The theme's accent, as UI Scale's segments: the Mac drew the track grey otherwise, in an active window.
            .tint(Color.hqTint)
            .accessibilityValue("\(points) points")
            .accessibilityIdentifier("theme.bubbleCorners")
        }
    }

    private func finish() {
        guard let draft else { return }
        self.draft = nil
        let points = Int(draft.rounded())
        if points != stored { commit(points) }
    }
}

/// [glass-bubbles] [tinted-bubbles] The style choices where they are offered, and their names.
@MainActor enum BubbleStyles {
    /// Solid, Glass and Tinted; the Mac has no glass (`GlassBubbles.offered`).
    static var offered: [BubbleStyle] { GlassBubbles.offered ? [.solid, .glass, .tinted] : [.solid, .tinted] }
    /// A stored style as it draws here: Glass is solid where it isn't offered.
    static func shown(_ stored: BubbleStyle) -> BubbleStyle { offered.contains(stored) ? stored : .solid }
}

extension BubbleStyle {
    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .tinted: "Tinted"
        }
    }
}

/// [tinted-bubbles] The space a preview's chat background fills: a Tinted bubble shows its slice of the soft copy laid
/// over it (`TintedBubbles`).
struct ChatGround {
    static let space = "hq.chatGround"
    var size: CGSize
}

/// [tinted-bubbles] The Chat Background as a chat draws it (the picture filling the panel from its centre, Dim over it)
/// behind `content`, in a rounded panel; with no Chat Background, `content` alone.
private struct ChatGroundPanel<Content: View>: View {
    @ViewBuilder var content: (ChatGround?) -> Content
    @Environment(\.colorScheme) private var scheme
    @State private var size = CGSize.zero
    @State private var ready = 0

    var body: some View {
        let _ = (Backdrop.chats.revision, Backdrop.app.revision, ready)
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        if let image = Backdrop.chats.drawn != nil ? Backdrop.chats.image(for: traits) : nil {
            content(size == .zero ? nil : ChatGround(size: size))
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background {
                    ZStack {
                        Color.hqPage
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                        Color.hqPage.opacity(Double(Backdrop.chats.dim) / 100)
                    }
                    .accessibilityHidden(true)
                }
                .coordinateSpace(.named(ChatGround.space))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .clipShape(.rect(cornerRadius: 12))
                .onReceive(NotificationCenter.default.publisher(for: Backdrop.pictureReady)) { _ in ready &+= 1 }
        } else {
            content(nil)
                .onReceive(NotificationCenter.default.publisher(for: Backdrop.pictureReady)) { _ in ready &+= 1 }
        }
    }
}

/// A reply and two of your messages, joined as in a chat, with the bot's tail (and yours unless Fewer Timestamps is on).
struct BubbleCornersPreview: View {
    var radius: CGFloat
    /// [glass-bubbles] [tinted-bubbles] Theme › Chat Bubbles › Style: drawn as the chat draws it (`GlassBubbles`,
    /// `TintedBubbles`), solid under Reduce Transparency.
    var style: BubbleStyle
    /// [tinted-bubbles] The chat background the preview stands on, in `ChatGround.space`; nil on a plain row.
    var ground: ChatGround?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: ChatMetrics.turnGap) {
            bubble("Your report is ready. It’s in Files, and I can send it to Ivy as well.", mine: false, tail: true)
            VStack(spacing: ChatMetrics.runGap) {
                bubble("Yes please", mine: true, joinsBelow: true, tail: false)
                bubble("Thanks!", mine: true, joinsAbove: true, tail: !ToolCallSettings.fewerTimestamps)
            }
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    private func bubble(_ text: String, mine: Bool, joinsAbove: Bool = false, joinsBelow: Bool = false, tail: Bool) -> some View {
        let glassy = style == .glass && GlassBubbles.offered && !reduceTransparency
        // Glass takes rounded corners only: no tail, its corner as round as the rest.
        let outline = BubbleOutline(radius: radius, mine: mine, joinsAbove: joinsAbove, joinsBelow: joinsBelow, tail: tail && !glassy)
        let colour = mine ? Color.hqMeBubble : Color.hqBotBubble
        let alpha = contrast == .increased ? GlassBubbles.contrastTint : mine ? GlassBubbles.ownTint : GlassBubbles.replyTint
        return Text(text)
            .font(Font.hq(.body))
            .foregroundStyle(mine ? Color.hqMeText : Color.hqLabel)
            .padding(.horizontal, ChatMetrics.bubblePadH)
            .padding(.vertical, ChatMetrics.bubblePadV)
            .background { tinted(mine: mine, in: outline) }
            .hqChatBubble(glassy ? colour.opacity(Double(alpha)) : nil, solid: tint(mine: mine) == nil ? colour : .clear, in: outline)
            // As wide as the chat lets each side go (`TextLayout.maxBubbleWidth`): a reply the row, yours a short column.
            .frame(maxWidth: mine ? ChatMetrics.userMaxWidth : ChatMetrics.replyMaxWidth, alignment: mine ? .trailing : .leading)
            // Room for the tail, which hangs outside the bubble.
            .padding(mine ? .trailing : .leading, ChatMetrics.tailSize.width)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

extension BubbleCornersPreview {
    /// [tinted-bubbles] The bubble's own copy of the picture, as a chat's bubble draws it (`BubbleShapeView`): nil
    /// unless Tinted is picked, Reduce Transparency is off and the preview stands on the chat background.
    private func tint(mine: Bool) -> (image: CGImage, aspect: CGSize)? {
        guard style == .tinted, !reduceTransparency, !Theme.isDesktop, ground != nil else { return nil }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = scheme == .dark ? .dark : .light
            traits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
        guard let soft = TintedBubbles.soft(for: traits),
              let image = TintedBubbles.image(soft, picture: Backdrop.chats.picture(for: traits),
                                              bubble: mine ? ChatPalette.meBubble : ChatPalette.botBubble, mine: mine,
                                              increaseContrast: contrast == .increased, traits: traits) else { return nil }
        return (image, soft.aspect)
    }

    @ViewBuilder private func tinted(mine: Bool, in outline: BubbleOutline) -> some View {
        if let ground, let tint = tint(mine: mine) {
            GeometryReader { proxy in
                let at = proxy.frame(in: .named(ChatGround.space))
                let fill = TintedBubbles.fillRect(tint.aspect, in: CGRect(origin: .zero, size: ground.size))
                // The whole picture, so the tail (outside the frame) shows its slice too.
                Image(decorative: tint.image, scale: 1)
                    .resizable()
                    .frame(width: fill.width, height: fill.height)
                    .offset(x: fill.minX - at.minX, y: fill.minY - at.minY)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .clipShape(outline)
        }
    }
}

/// The chat's own bubble outline (`BubbleShape`) at a given corner.
/// [desktop-corners] The Desktop Look's Corners as its chats draw them: a reply straight on the page, your message in
/// its bordered box, and the text box below (`ComposerView`: the glass bar 4 pt rounder than the boxes, up to its own
/// corner; or the desktop's flat box at the boxes' corner).
private struct DesktopCornersPreview: View {
    var radius: CGFloat
    var composer: DesktopComposer

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.turnGap + 6) {
            Text("Your report is ready. It’s in Files, and I can send it to Ivy as well.")
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Thanks!")
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqMeText)
                .padding(.horizontal, ChatMetrics.bubblePadH)
                .padding(.vertical, ChatMetrics.bubblePadV)
                .background(Color.hqMeBubble, in: box(height: 36))
                .overlay(box(height: 36).strokeBorder(Color(uiColor: ChatPalette.meBorder), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .trailing)
            textBox
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    private func box(height: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: min(radius, height / 2)) }

    @ViewBuilder private var textBox: some View {
        switch composer {
        case .glass:
            // Two rows, as the iOS look's bar: the words across the top, + and the circle below.
            let shape = RoundedRectangle(cornerRadius: min(26, radius + 4))
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2).padding(.horizontal, 16).padding(.top, 12)
                HStack {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.hqLabel)   // a11y-font-ok: a small picture of the bar, its glyphs drawn at the bar's own sizes
                        .frame(width: 36, height: 36).hqComposerGlass(in: Circle())
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.hqOnTint)   // a11y-font-ok: as above
                        .frame(width: 36, height: 36).hqComposerGlass(tint: Color.hqTint.opacity(0.7), in: Circle())
                }
                .padding(8)
            }
            .hqComposerGlass(in: shape)
        case .box:
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Color.hqLabel2)   // a11y-font-ok: a small picture of the box
                Text("Message").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                Spacer()
                Circle().fill(Color.hqLabel).frame(width: 28, height: 28)
                    .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hqPage))   // a11y-font-ok: as above
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(uiColor: ChatPalette.editor), in: box(height: 46))
            .overlay(box(height: 46).strokeBorder(Color.hqStroke, lineWidth: 1))
        }
    }
}

nonisolated private struct BubbleOutline: Shape {
    var radius: CGFloat
    var mine: Bool
    var joinsAbove: Bool
    var joinsBelow: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let key = BubbleShape.Key(width: rect.width, height: rect.height, mine: mine, joinsAbove: joinsAbove, joinsBelow: joinsBelow, tail: tail)
        return Path(BubbleShape.path(key, radius: radius)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The desktop's section label: 12 pt semibold capitals, tracked, in the secondary colour (phone-ui-desktop.css:96-104).
struct DesktopLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Font.hqSystem(size: 12 * HQFont.dynamicRatio(nil), weight: .semibold))
            .tracking(12 * 0.08)
            .foregroundStyle(Color.hqLabel2)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One group of the Desktop Look: rows on the page inside a 4 pt outlined box, its note under it.
private struct DesktopGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // [mac] Mac polish #94: the form's row inset and one-row height, as every other Settings page's boxes (this
            // one was 11 pt shorter, its words 6 pt further left), and the note under the words, not the box's edge.
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, DeviceWord.isMac ? MacInset.side : 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: DeviceWord.isMac ? MacForm.settingsRowHeight : nil, alignment: .leading)
                .background(Color.hqPage)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hqStroke, lineWidth: 1))
            if let footer {
                Text(footer).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DeviceWord.isMac ? MacInset.side : 0)
            }
        }
    }
}

/// UI Scale's five presets as the desktop's outlined segments: one bordered box, the chosen one filled with the
/// accent (phone-ui-desktop.css segmented control). One element per preset, the chosen one marked selected.
private struct ScaleSegments: View {
    var selected: Int
    var pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ThemeState.scalePresets.enumerated()), id: \.element) { index, percent in
                let on = percent == selected
                let last = index == ThemeState.scalePresets.count - 1
                Button { pick(percent) } label: {
                    Text("\(percent)%")
                        .font(Font.hq(.footnote).weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.hqOnTint : Color.hqLabel)
                        // [mac] No shrinking to fit on the Mac (a candidate in the Mac 479 layout-loop crash: a label that may
                        // scale measures differently pass to pass); the Mac's segments are wide enough at every UI Scale.
                        .lineLimit(1).minimumScaleFactor(DeviceWord.isMac ? 1 : 0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        // The fill's own corners (the box isn't clipped: a clip would cut the taller hit area below).
                        .background(on ? Color.hqTint : Color.clear,
                                    in: UnevenRoundedRectangle(topLeadingRadius: index == 0 ? 4 : 0, bottomLeadingRadius: index == 0 ? 4 : 0,
                                                               bottomTrailingRadius: last ? 4 : 0, topTrailingRadius: last ? 4 : 0))
                        // UX #160: drawn 36 pt tall, touched over 44 pt.
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -4)
                .accessibilityLabel("\(percent)%")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("theme.uiScale.\(percent)")
                if index < ThemeState.scalePresets.count - 1 {
                    Rectangle().fill(Color.hqStroke).frame(width: 1, height: 36)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hqStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("UI Scale")   // UX #160: VoiceOver names the group on entering it
        .accessibilityIdentifier("theme.uiScale")
    }
}

// MARK: - Skin grid

struct SkinGrid: View {
    var selected: String
    var dark: Bool
    var oneColumn: Bool
    var pick: (String) -> Void

    var body: some View {
        // Not a LazyVGrid: Mac download 479 died "stuck in a recursive layout loop" (self-sizing rows not returning the
        // same size twice) in this page's List a moment after a theme change. A lazy grid sizes by the cards it has made
        // so far; in a List row that height can differ from pass to pass. A dozen cards gain nothing from laziness.
        let count = oneColumn ? 1 : 2
        let skins = SkinCatalog.all
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: skins.count, by: count)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(start..<start + count, id: \.self) { index in
                        if index < skins.count {
                            let skin = skins[index]
                            SkinCard(skin: skin, dark: dark, isSelected: skin.id == selected) { pick(skin.id) }
                        } else {
                            Color.clear.frame(height: 0)   // an odd last row keeps its card one column wide
                        }
                    }
                }
            }
        }
        // [page-tabs] Its own height whatever the row offers. The List offers the row's height back, and a Grid given a
        // height shrinks its last row to fit (980 pt wanted, 963 then 961 given back, Cyberpunk's taller card spilling
        // out), so the row came out 20 pt taller than the grid and the grid sat 10 pt down in it, under the tabs.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SkinCard: View {
    var skin: Skin
    var dark: Bool
    var isSelected: Bool
    var action: () -> Void

    private var spokenLabel: String { [skin.label, skin.onlyModeTag, skin.description].compactMap { $0 }.joined(separator: ", ") }

    private var name: some View { Text(skin.label).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel) }

    // Stress test 2026-10-28 #88 (both): the grid didn't say which themes ignore Light and Dark; their card says so,
    // which also tells apart dark previews that look alike in a dark window.
    @ViewBuilder private var modeTag: some View {
        if let tag = skin.onlyModeTag { SkinModeTag(text: tag) }
    }

    var body: some View {
        let desktop = Theme.shared.state.desktopLook
        // iOS look: the grouped card's own corner (26 pt on iOS 26), so the list's rounded edge never cuts a card's outline.
        let radius: CGFloat = desktop ? 4 : 26
        // The card previews the skin as it would draw now (the look, the contrast option and the mode on screen).
        var preview = Theme.shared.state
        preview.skinID = skin.id
        let resolved = ThemeResolver.resolve(preview)
        let tokens = resolved.tokens(dark: dark)
        let previewRadius: CGFloat = desktop ? 3 : 14
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if DeviceWord.isMac {
                        // [mac] Stress test 2026-10-28 #88, round 2: in a dark window Nous, GitHub, Catppuccin, Solarized
                        // and Nous Alt previewed as near-identical dark pages. A theme with both looks shows both, its
                        // light page beside its dark one; every preview leads with a filled bar of its own accent.
                        if skin.onlyModeTag == nil {
                            HStack(spacing: 0) {
                                SkinPreview(tokens: resolved.tokens(dark: false), radius: 0, accentBar: true)
                                SkinPreview(tokens: resolved.tokens(dark: true), radius: 0, accentBar: true)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: previewRadius))
                            .overlay(RoundedRectangle(cornerRadius: previewRadius).strokeBorder(Color.hqStroke, lineWidth: 1))
                        } else {
                            SkinPreview(tokens: tokens, radius: previewRadius, accentBar: true)
                        }
                    } else {
                        SkinPreview(tokens: tokens, radius: previewRadius)
                    }
                }
                .frame(height: desktop ? 64 : 56)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // [page-tabs] The name whole: beside its tag while both fit, else the tag under it ("Cyberp…" in
                    // the iOS look, "Cyberpun / k" in the Desktop Look).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            name.fixedSize()
                            modeTag
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            name
                            modeTag
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hqTintText)
                            .accessibilityHidden(true)
                    }
                }
                Text(skin.description).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            // [compact] iOS look 124 pt (was 150): no empty band under the shorter descriptions.
            .frame(maxWidth: .infinity, minHeight: desktop ? 150 : 124, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius).fill(desktop ? Color.hqPage : Color(uiColor: HQPalette.card)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(isSelected ? Color.hqTintText : (desktop ? Color.hqStroke : Color.clear), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        // One stop for VoiceOver, speaking the label below. (XCUITest's tree still lists the card's inner texts under
        // the button whatever is hidden from accessibility: tried in repair round 1, so no test can assert on it.)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("theme.skin.\(skin.id)")
    }
}

/// "Dark Only" / "Light Only" on a one-palette theme's card (stress test 2026-10-28 #88).
private struct SkinModeTag: View {
    var text: String

    var body: some View {
        if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #88, round 2: the outlined tag was easy to miss; it is a filled tag with the
            // moon (or sun) of the one look the theme has.
            Label(text, systemImage: text.hasPrefix("Dark") ? "moon.fill" : "sun.max.fill")
                .labelStyle(.titleAndIcon)
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.hqFill3))
        } else {
        Text(text)
            .font(Font.hq(.caption))
            .foregroundStyle(Color.hqLabel2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.hqStroke, lineWidth: 1))
        }
    }
}

/// The skin's page with a strip of its card colour, an accent dot and two text bars in its label colours.
private struct SkinPreview: View {
    var tokens: ThemeTokens
    var radius: CGFloat
    /// [mac] Stress test 2026-10-28 #88, round 2: a filled accent bar instead of a 12 pt dot, and bars that shrink to
    /// fit half a card (the light and dark halves).
    var accentBar = false

    private func colour(_ value: RGBA) -> Color { Color(uiColor: value.uiColor) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            colour(tokens.page)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if accentBar {
                        RoundedRectangle(cornerRadius: 3).fill(colour(tokens.tint)).frame(minWidth: 14, maxWidth: 30, minHeight: 12, maxHeight: 12)
                        Capsule().fill(colour(tokens.label)).frame(minWidth: 10, maxWidth: 54, minHeight: 6, maxHeight: 6)
                    } else {
                    Circle().fill(colour(tokens.tint)).frame(width: 12, height: 12)
                    Capsule().fill(colour(tokens.label)).frame(width: 54, height: 6)
                    }
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3).fill(colour(tokens.meBubble))
                        .frame(minWidth: accentBar ? 12 : 34, maxWidth: 34, minHeight: 12, maxHeight: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colour(tokens.meBorder), lineWidth: 1))
                }
                Capsule().fill(colour(tokens.label2)).frame(minWidth: accentBar ? 20 : 84, maxWidth: 84, minHeight: 5, maxHeight: 5)
                RoundedRectangle(cornerRadius: 3).fill(colour(tokens.groupedCard.over(tokens.page)))
                    .frame(height: 14)
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(colour(tokens.separator), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Hermes HQ Themes for Desktop

@MainActor @Observable
final class DesktopThemeInstallerModel {
    enum Phase: Equatable { case idle, adding, added, failed(Int) }

    @ObservationIgnored private weak var services: (any AppServices)?
    private(set) var targets: [GatewayAccountRow] = []
    private(set) var phases: [String: Phase] = [:]
    /// The app's own copy of the theme file is readable (stress item 11: no Add button otherwise).
    private(set) var fileReady = true
    var copied = false
    var copyFailed = false
    /// Tests swap the call; the app uses each computer's own saved sign-in.
    @ObservationIgnored var makeCall: ((GatewayAccountRow) -> DesktopThemeInstall.Call?)?

    init(services: (any AppServices)?) {
        self.services = services
    }

    func refresh() {
        let rows = (services as? SettingsServices)?.gateways.accounts ?? []
        targets = DesktopThemeInstall.targets(rows)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugNoThemeFile") { fileReady = false; return }
        #endif
        fileReady = DesktopThemeInstall.bundledText() != nil
    }

    func phase(_ row: GatewayAccountRow) -> Phase { phases[row.id] ?? .idle }

    private func call(for row: GatewayAccountRow) -> DesktopThemeInstall.Call? {
        if let makeCall { return makeCall(row) }
        guard let app = services as? AppModel, let stored = app.signIn.store.stored(row.account) else { return nil }
        // DECISION: every target, the one in use included, is reached with its own saved sign-in (AccountREST): it
        // answers with the HTTP status the failure words need, and never opens a socket or switches gateways.
        // The computer in use has a live connection of its own: a refusal of this one-off session must never erase
        // its saved sign-in (`persisted: false`). Tailscale off: answer at once instead of waiting out the timeout.
        let inUse = row.isCurrent
        return { path, body in
            if let base = URL(string: stored.url), !GatewayAddress.reachable(base) { return 0 }
            let answer = await AccountREST.call(stored, method: "POST", path: path, body: body,
                                                timeout: DesktopThemeInstall.timeout, persisted: !inUse)
            return DesktopThemeInstall.status(answer.status, body: answer.data)
        }
    }

    func add(_ row: GatewayAccountRow) {
        guard phase(row) != .adding else { return }          // a second tap while it runs does nothing
        guard let content = DesktopThemeInstall.bundledText() else { fileReady = false; return }
        guard let call = call(for: row) else {
            phases[row.id] = .failed(401)
            Haptics.play(.error)
            return
        }
        phases[row.id] = .adding
        let tag = AppLog.tag(row.id)
        let start = ContinuousClock.now
        Task {
            let failure = await DesktopThemeInstall.install(content: content, call: call)
            phases[row.id] = failure.map(Phase.failed) ?? .added
            if let failure {
                AppLog.note("settings", "desktop theme install on \(tag) failed after \(AppLog.ms(since: start)) ms: status \(failure)")
            } else {
                AppLog.trace("settings", "desktop theme install on \(tag) ok in \(AppLog.ms(since: start)) ms")
            }
            Haptics.play(failure == nil ? .success : .error)
            let words = failure.map(DesktopThemeInstall.failureWords) ?? DesktopThemeInstall.addedNote
            HQAnnounce.say(words)
        }
    }

    func copyLink() {
        UIPasteboard.general.string = DesktopThemeInstall.link
        // The pasteboard is read back only where that shows no paste prompt (it holds what this app just put there).
        let confirmed = UIPasteboard.general.hasStrings
        copied = confirmed
        copyFailed = !confirmed
        Haptics.play(confirmed ? .success : .error)
        #if DEBUG
        DebugHooks.recordText(DesktopThemeInstall.link, as: "theme-link.txt")
        #endif
    }
}

struct DesktopThemeRows: View {
    var model: DesktopThemeInstallerModel
    /// A bordered button pads its label by 7 pt above and below: 30 pt of label makes the 44 pt touch target in the
    /// Desktop Look. The iOS look uses small capsules like the App Store's Get (owner 2026-10-16: the card was too big).
    static var buttonLabelHeight: CGFloat { Theme.isDesktop ? 30 : 0 }
    /// At the accessibility text sizes a title and its button no longer fit side by side (stress round 2: the title
    /// broke inside words and "Added" wrapped): the button goes under the title, as the skin grid goes to one column.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A title with its button: side by side, stacked at the accessibility sizes.
    @ViewBuilder private func titled<Title: View, Trailing: View>(@ViewBuilder _ title: () -> Title,
                                                                 @ViewBuilder trailing: () -> Trailing) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) { title(); trailing() }
        } else {
            HStack(alignment: .center, spacing: 12) { title(); trailing() }
        }
    }

    var body: some View {
        let targets = model.fileReady ? model.targets : []
        Group {
            VStack(alignment: .leading, spacing: 8) {
                titled {
                    Text("Hermes HQ Themes for Desktop").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("theme.desktop.title")
                } trailing: {
                    if targets.count == 1 { addButton(targets[0]) }
                }
                Text(DesktopThemeInstall.description(targets: targets))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("theme.desktop.description")
                if targets.count == 1 { note(targets[0]) }
            }
            .padding(.vertical, Theme.isDesktop ? 8 : 2)   // [compact] iOS look: the List row pads it already

            if targets.count > 1 {
                ForEach(targets) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        titled {
                            Text("\(Text(row.title).foregroundStyle(Color.hqLabel))\(Text(row.isCurrent ? " · In Use" : "").foregroundStyle(Color.hqLabel2))")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("theme.desktop.row.\(row.id)")
                        } trailing: {
                            addButton(row)
                        }
                        note(row)
                    }
                    .frame(minHeight: Theme.isDesktop ? 44 : 0)
                    // [compact] iOS look: the capsule's 44 pt touch target reaches into the List row's own padding
                    // instead of adding to it (owner 2026-10-17: a one-line computer row was ~80 pt tall).
                    .padding(.vertical, Theme.isDesktop ? 6 : -RowActionButtonStyle.targetOverhang)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.copyFailed {
                    Text(DesktopThemeInstall.copyFailedNote).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                        .textSelection(.enabled)
                } else {
                    Text(model.copied ? DesktopThemeInstall.copiedNote : DesktopThemeInstall.elsewhereNote)
                        .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("theme.desktop.elsewhere")
                }
                Button { model.copyLink() } label: {
                    Text(model.copied ? "Copied" : "Copy Link").frame(minHeight: Self.buttonLabelHeight)
                }
                    .hqRowActionButtonStyle()
                    .accessibilityLabel(model.copied ? "Copied" : "Copy Install from Git Link")
                    .accessibilityIdentifier("theme.desktop.copyLink")
                    .padding(.vertical, Theme.isDesktop ? 0 : -RowActionButtonStyle.targetOverhang)
            }
            .padding(.vertical, Theme.isDesktop ? 8 : 2)
        }
    }

    @ViewBuilder private func addButton(_ row: GatewayAccountRow) -> some View {
        let phase = model.phase(row)
        let button = Button {
            model.add(row)
        } label: {
            HStack(spacing: 6) {
                if phase == .adding { ProgressView().controlSize(.small) }
                Text(phase == .adding ? "Adding…" : phase == .added ? "Added" : "Add").lineLimit(1).fixedSize()
            }
            .frame(minHeight: Self.buttonLabelHeight)
        }
        .disabled(phase == .adding)
        .accessibilityLabel("Add to \(row.title)")
        .accessibilityValue(phase == .adding ? "Adding…" : phase == .added ? "Added" : "")
        .accessibilityIdentifier("theme.desktop.add.\(row.id)")
        button.hqRowActionButtonStyle(prominent: phase != .added)
    }

    @ViewBuilder private func note(_ row: GatewayAccountRow) -> some View {
        switch model.phase(row) {
        case .added:
            Text(DesktopThemeInstall.addedNote).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                .accessibilityIdentifier("theme.desktop.note.\(row.id)")
        case .failed(let status):
            Text(DesktopThemeInstall.failureWords(status)).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                .accessibilityIdentifier("theme.desktop.note.\(row.id)")
        default:
            EmptyView()
        }
    }
}
