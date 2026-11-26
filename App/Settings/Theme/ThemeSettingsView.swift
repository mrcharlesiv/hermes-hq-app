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
// [appearance-groups] Owner 2026-11-18 ("we just kept cramming in new features"): the Theme page is the themes only:
// the grid, High Contrast (the Desktop Look's) and the desktop app's themes. Desktop Look, UI Scale, Density, Top Edge
// and Working Ring are rows of Settings › Appearance's groups (`AppearanceSections`); the Desktop Look's Corners and
// Text Box are on Chat Bubbles.

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
    private var theme: Theme { Theme.shared }

    static var lookNote: String { "Draws Hermes HQ like the Hermes desktop app: your theme’s own colors on every screen, square corners and solid bars instead of glass. \(DeviceWord.onlyHere)" }
    static let contrastNote = "Sets your messages, boxes, lines and secondary text further apart from the page, in your theme’s own colors. For themes that look flat."
    /// [density] Both looks on the iPhone and iPad too (it was the Desktop Look's only, the iOS look staying at 100 %).
    static var scaleNote: String { DeviceWord.isMac ? macScaleNote : "Makes text, faces and rows larger or smaller, in both looks, on top of the text size set in \(DeviceWord.settingsApp). \(DeviceWord.onlyHere)" }
    /// Concise note for Appearance › Text Size (device scope lives once in Appearance's bottom footer).
    static var conciseScaleNote: String {
        DeviceWord.isMac
            ? "Makes text, faces and rows larger or smaller, in both looks. View › Make Text Bigger (⌘+) and Make Text Smaller (⌘−) change it too."
            : "Makes text, faces and rows larger or smaller, in both looks, on top of the text size set in \(DeviceWord.settingsApp)."
    }
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
    static let gridNote = "Themes include the Hermes desktop app's themes and app-only options. Light or Dark (set in Appearance) applies on top."

    var body: some View {
        page(theme.state)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .init("HQDebugFlipLook"))) { _ in
                theme.setDesktopLook(!theme.state.desktopLook)
            }
            #endif
    }

    private func page(_ state: ThemeState) -> some View {
        Group {
            if state.desktopLook {
                // The Desktop Look's page: plain rows on the page colour, each group in a 4 pt outlined box
                // (phone-ui-desktop.css:139-148). Not a List: iOS's grouped cards keep their own round corners.
                ScrollView {
                    // UX #118: no "Theme" label over the grid, under a bar already titled Theme.
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            grid(state)
                            gridFooter(state).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
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
                    Section {
                        grid(state)
                            .padding(.bottom, 4)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .hqDesktopBareRow()
                    } footer: { HQSectionFooter {
                        gridFooter(state)
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
        ThemeState.textBoxIsFixed ? "How round your messages and the message box are. 4 pt is the Hermes desktop app’s."
            : "How round your messages and the text box are. 4 pt is the Hermes desktop app’s. Liquid Glass is the \(DeviceWord.name)’s own text box, rounded to match; Hermes is the desktop app’s flat box."
    }

    /// [a11y] iOS Increase Contrast (the debug override too) turns High Contrast on: the switch shows it, and is held.
    private var increaseContrast: Bool { systemContrast == .increased || HQAccessibility.overrides.contrast }

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
        let opener = BackgroundOpener()
        let page = SettingsPageController(title: "Chat Bubbles", ChatBubblesSettingsView(openChatBackground: { opener.open(.chats) }))
        opener.host = page
        page.view.accessibilityIdentifier = "settings.chat-bubbles"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct ChatBubblesSettingsView: View {
    var openChatBackground: (() -> Void)? = nil
    private var theme: Theme { Theme.shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var note: String {
        GlassBubbles.offered
            ? "How round the corners of messages in chats are, and how they’re filled: Solid, Liquid Glass in your theme’s colors, or Tinted with the colors of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Hermes Look has its own Corners, here once it is on. \(DeviceWord.onlyHere)"
            : "How round the corners of messages in chats are, and whether they’re Tinted with the colors of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Hermes Look has its own Corners, here once it is on. \(DeviceWord.onlyHere)"
    }
    /// [bubbles-note] One-line summary of each bubble style.
    static func styleLine(_ style: BubbleStyle) -> String {
        switch style {
        case .glass: "Glass: Liquid Glass in your theme’s colors."
        case .tinted: "Tinted: the colors of your Chat Background."
        case .card: "Card: replies are soft cards, as App Background’s Soft Cards. Your messages are Tinted."
        default: "Solid: filled with your theme’s colors."
        }
    }
    static var shortNote: String {
        "Override a single bot’s bubble color in Bot Info › Settings."
    }

    /// [message-colour] What Colour changes, and what Theme means in its row.
    static var colourNote: String {
        let faces = "Bot’s Face gives each bot’s chat the color of its face. A bot can have its own color in Bot Info › Settings."
        return DeviceWord.isMac
            ? "Color is for your own messages and the row chosen in the sidebar. Theme keeps your theme’s color. \(faces)"
            : "Color is for your own messages. Theme keeps your theme’s color. \(faces)"
    }

    /// [tinted-bubbles] Tinted picked with no Chat Background: it has no colours to take.
    static let tintedNeedsBackground = "Tinted takes its colors from your Chat Background. Choose one in Appearance › Backgrounds; until then, messages are solid."

    var body: some View {
        let _ = Backdrop.chats.revision
        let state = theme.state
        // UX #118: no "Chat Bubbles" header, under a bar already titled Chat Bubbles.
        List { Group {
            if state.desktopLook { desktopSection(state) } else { bubbleSections(state) }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
    }

    /// [desktop-corners] [desktop-composer] [plain-replies] The Desktop Look's own Corners for messages, Reply Bubbles
    /// (when High Contrast is on), and its Text Box style.
    @ViewBuilder private func desktopSection(_ state: ThemeState) -> some View {
        Section {
            BubbleCornersRow(stored: state.desktopCorners, standard: ThemeState.defaultDesktopCorners,
                             style: .solid, composer: state.boxComposer ? .box : .glass,
                             plainReply: state.appliedPlainReplies) { points in
                theme.setBubbleCorners(points)
            }
            .hqRowPadding(4)

            replyBubblesRow(
                state,
                disabledNote: state.contrastApplies ? nil : "Hermes Look draws replies straight on the page unless High Contrast is on."
            )

            // [mac] The Mac keeps its own message box: no Text Box choice there.
            if !ThemeState.textBoxIsFixed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Text Box").foregroundStyle(Color.hqLabel).fixedSize()   // [ui-sizing] whole beside its segments
                    HQSegmentedPicker("Text Box", options: [("Hermes", DesktopComposer.box), ("Liquid Glass", DesktopComposer.glass)],
                                      selection: Binding(get: { state.desktopComposer }, set: { next in
                                          guard next != state.desktopComposer else { return }
                                          Haptics.play(.selection)
                                          theme.setDesktopComposer(next)
                                          AppLog.trace("settings", "desktop text box \(next.rawValue)")
                                      }), ticks: false)
                }
                .hqRowPadding(4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("theme.desktopComposer")
            }
        } footer: { HQSectionFooter {
            Text(ThemeSettingsView.desktopChatsNote)
        } }
    }

    /// [plain-replies] Chat Bubbles › Reply Bubbles toggle, disabled with a note when the look or skin already draws
    /// replies straight on the page.
    @ViewBuilder private func replyBubblesRow(_ state: ThemeState, disabledNote: String?) -> some View {
        let forcedPlain = disabledNote != nil
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Reply Bubbles", isOn: Binding(get: { !forcedPlain && !state.plainReplies }, set: { setPlainReplies(!$0) }))
                .tint(Color.hqTint)
                .disabled(forcedPlain)
                .accessibilityIdentifier("theme.replyBubbles")
            if let disabledNote {
                Text(disabledNote)
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("theme.replyBubblesNote")
            }
        }
    }

    /// True when the active skin draws replies straight on the page (Paper), so Reply Bubbles is synced off.
    private func skinDrawsPlainReplies(_ state: ThemeState) -> Bool {
        guard let own = state.skin.ownLook?.pick(scheme == .dark) else { return false }
        return own.reply == own.page
    }

    @ViewBuilder private func bubbleSections(_ state: ThemeState) -> some View {
        let paperPlain = skinDrawsPlainReplies(state)
        let colorMode: String = switch state.messageColour {
        case .theme: "theme"
        case .botFace, .face: "botFace"
        case .preset, .custom: "custom"
        }
        Section {
            BubbleCornersRow(stored: state.bubbleCorners, standard: ThemeState.defaultBubbleCorners,
                             style: bubbleStyle(state), plainReply: paperPlain || state.plainReplies,
                             messageColour: state.messageColour) { points in
                theme.setBubbleCorners(points)
            }
            .hqRowPadding(4)

            bubbleStylePicker(state)

            replyBubblesRow(
                state,
                disabledNote: paperPlain ? "\(state.skin.label) draws replies straight on the page." : nil
            )

            // [message-colour] Mode (Theme | Bot's Face | Custom) split cleanly above the 9 hue presets + custom color well.
            ColourSwatchRow(
                title: "Your Message Color",
                value: state.messageColour.title,
                state: state,
                swatches: MessageColour.Preset.allCases.map { ColourSwatch(.preset($0)) },
                picked: state.messageColour.swatchID,
                custom: state.messageColour.customHex,
                modeStrip: .init(
                    options: [("Theme", "theme"), ("Bot’s Face", "botFace"), ("Custom", "custom")],
                    selected: colorMode
                ) { next in
                    switch next {
                    case "theme": setColour(.theme)
                    case "botFace": setColour(.botFace)
                    default:
                        if case .preset = state.messageColour { return }
                        if case .custom = state.messageColour { return }
                        setColour(.preset(.blue))
                    }
                },
                identifier: "theme.messageColour"
            ) { swatch in
                setColour(MessageColour(stored: swatch.id))
            } pickCustom: { hex in
                setColour(.custom(hex))
            }
            .hqRowPadding(4)
        } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.shortNote).accessibilityIdentifier("theme.messageColourNote")
                if reduceTransparency {
                    Text("With Reduce Transparency on, messages stay solid.")
                }
            }
        } }
    }

    /// [plain-replies] What Reply Bubbles changes.
    static let replyBubblesNote = "Off: a bot’s replies have no bubble. Their words go the full width of the chat, straight on the page. Your own messages keep theirs."

    /// [plain-replies] Chat Bubbles › Reply Bubbles.
    private func setPlainReplies(_ on: Bool) {
        guard on != theme.state.plainReplies else { return }
        Haptics.play(.selection)
        theme.setPlainReplies(on)
        AppLog.trace("settings", "reply bubbles \(on ? "off" : "on")")
    }

    /// [message-colour] Chat Bubbles › Colour.
    private func setColour(_ colour: MessageColour) {
        guard colour != theme.state.messageColour else { return }
        theme.setMessageColour(colour)
        AppLog.trace("settings", "message colour \(colour.stored ?? "theme")")
    }

    /// [glass-bubbles] [tinted-bubbles] The style the chats draw: Glass reads as Solid where it isn't offered (the Mac).
    private func bubbleStyle(_ state: ThemeState) -> BubbleStyle { BubbleStyles.shown(state.bubbleStyle) }

    /// [glass-bubbles] [tinted-bubbles] [bubble-card] Four styles (`Solid | Glass | Tinted | Card`) stacked cleanly, with
    /// an inline CTA to add a Chat Background whenever Tinted or Card is picked without one.
    @ViewBuilder private func bubbleStylePicker(_ state: ThemeState) -> some View {
        let style = bubbleStyle(state)
        let needsBg = (style == .tinted || style == .card) && Backdrop.chats.drawn == nil
        let pick = { (next: BubbleStyle) in
            guard next != style else { return }
            Haptics.play(.selection)
            theme.setBubbleStyle(next)
            AppLog.trace("settings", "bubble style \(next.rawValue)")
        }
        VStack(alignment: .leading, spacing: 10) {
            if GlassBubbles.offered {
                HStack(alignment: .firstTextBaseline) {
                    Text("Style").foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 8)
                    Text(needsBg ? "\(style.title) (needs background)" : style.title)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("theme.bubbleStyleLine")
                }
                HQSegmentedPicker("Style", options: BubbleStyles.offered.map { ($0.title, $0) },
                                  selection: Binding(get: { style }, set: { pick($0) }), ticks: false, wholeLabels: true)
                    .labelsHidden()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("theme.bubbleStyle")
            } else {
                Toggle("Tinted", isOn: Binding(get: { style == .tinted }, set: { pick($0 ? .tinted : .solid) }))
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("theme.tintedBubbles")
            }
            if needsBg, let openChatBackground {
                Button {
                    Haptics.play(.selection)
                    openChatBackground()
                } label: {
                    HStack(spacing: 8) {
                        Text("Add a Chat Background for \(style.title)")
                            .font(Font.hq(.footnote).weight(.medium))
                            .foregroundStyle(Color.hqTintText)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(Font.hq(.caption).weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("theme.tintedNeedsBackground")
            }
        }
        .hqRowPadding(4)
    }
}

/// Theme › Chat Bubbles: a few bubbles drawn as the chat draws them, and a slider for their corner. The preview follows
/// the drag; the chats only change when the slider is let go (each change lays every open chat out again).
private struct BubbleCornersRow: View {
    var stored: Int
    var standard: Int = ThemeState.defaultBubbleCorners
    var style: BubbleStyle
    /// [desktop-corners] Set in the Desktop Look: its preview, with the text box this look draws.
    var composer: DesktopComposer?
    /// [plain-replies] Reply Bubbles off: the preview's reply has no bubble, as in the chat.
    var plainReply = false
    /// Active message color pick (for live Bot's Face preview).
    var messageColour: MessageColour = .theme
    var commit: (Int) -> Void
    @State private var draft: Double?
    @State private var dragging = false

    private static let range = ThemeState.bubbleCornerRange
    private static let ticks = [0, 4, 12, 18, 24]

    var body: some View {
        let points = Int((draft ?? Double(stored)).rounded())
        VStack(alignment: .leading, spacing: 10) {
            // [tinted-bubbles] On the Chat Background where there is one: the styles are told apart on it.
            if let composer {
                DesktopCornersPreview(radius: CGFloat(points), composer: composer, boxedReply: !plainReply)
            } else {
                ChatGroundPanel { ground in
                    BubbleCornersPreview(radius: CGFloat(points), style: style, ground: ground,
                                         plainReply: plainReply, previewBotFace: messageColour == .botFace)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Corners").foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text("\(points) pt").monospacedDigit().foregroundStyle(Color.hqLabel2)
                if points != standard {
                    Button("Reset") {
                        Haptics.play(.selection)
                        draft = nil
                        commit(standard)
                    }
                    .font(Font.hq(.footnote).weight(.medium))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme.bubbleCornersReset")
                }
            }
            VStack(spacing: 2) {
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

                HStack {
                    ForEach(Self.ticks, id: \.self) { tick in
                        Text("\(tick)")
                            .font(Font.hq(.caption2))
                            .monospacedDigit()
                            .foregroundStyle(tick == points ? Color.hqLabel : Color.hqLabel3)
                        if tick != Self.ticks.last { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 26)
                .accessibilityHidden(true)
            }
        }
    }

    private func finish() {
        guard let draft else { return }
        self.draft = nil
        let points = Int(draft.rounded())
        if points != stored { commit(points) }
    }
}

/// [glass-bubbles] [tinted-bubbles] [bubble-card] The four bubble style choices (`Solid | Glass | Tinted | Card`) and their names.
@MainActor enum BubbleStyles {
    /// Solid, Glass, Tinted and Card; the Mac has no glass (`GlassBubbles.offered`).
    static var offered: [BubbleStyle] { GlassBubbles.offered ? [.solid, .glass, .tinted, .card] : [.solid, .tinted] }
    /// A stored style as it draws here: Glass and Card are solid where they aren't offered.
    static func shown(_ stored: BubbleStyle) -> BubbleStyle { offered.contains(stored) ? stored : .solid }
}

extension BubbleStyle {
    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .tinted: "Tinted"
        case .card: "Card"
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

/// A reply and your message with inline timestamps (and an honest Bot's Face preview chip when Bot's Face is active).
struct BubbleCornersPreview: View {
    var radius: CGFloat
    /// [glass-bubbles] [tinted-bubbles] Theme › Chat Bubbles › Style: drawn as the chat draws it (`GlassBubbles`,
    /// `TintedBubbles`), solid under Reduce Transparency.
    var style: BubbleStyle
    /// [tinted-bubbles] The chat background the preview stands on, in `ChatGround.space`; nil on a plain row.
    var ground: ChatGround?
    /// [plain-replies] Reply Bubbles off: the reply's words straight on the page, no bubble or tail.
    var plainReply = false
    /// When `MessageColour.botFace` is active, preview a real bot face's tint with an explanatory chip.
    var previewBotFace = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private static let sampleHead = Head.defaultHead(profile: "otto")

    /// Resolved user bubble & ink colors for the preview (showing Otto's real face color when `previewBotFace` is true).
    private var meColors: (uiFill: UIColor, fill: Color, uiInk: UIColor, ink: Color) {
        guard previewBotFace else {
            return (ChatPalette.meBubble, Color.hqMeBubble, ChatPalette.meText, Color.hqMeText)
        }
        var probe = Theme.shared.state
        probe.desktopLook = false
        probe.messageColour = Self.sampleHead.messageColour
        let resolved = ThemeResolver.resolve(probe)
        let uiFill = UIColor { traits in resolved.tokens(dark: traits.userInterfaceStyle == .dark).meBubble.uiColor }
        let uiInk = UIColor { traits in resolved.tokens(dark: traits.userInterfaceStyle == .dark).meText.uiColor }
        return (uiFill, Color(uiColor: uiFill), uiInk, Color(uiColor: uiInk))
    }

    var body: some View {
        VStack(spacing: ChatMetrics.turnGap) {
            if previewBotFace {
                HStack(spacing: 6) {
                    HeadImage(head: Self.sampleHead, size: 18)
                    Text("Previewing Otto’s face color")
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.hqFill3, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .center)
            }
            bubble("Your report is ready. It’s in Files, and I can send it to Ivy too.", time: "2:45 PM", mine: false, tail: true)
            bubble("Thanks!", time: "2:46 PM", mine: true, tail: !ToolCallSettings.fewerTimestamps)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bubble(_ text: String, time: String, mine: Bool, joinsAbove: Bool = false, joinsBelow: Bool = false, tail: Bool) -> some View {
        if plainReply && !mine {
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel)
                Text(time)
                    .font(Font.hq(.caption2))
                    .foregroundStyle(Color.hqLabel2)
            }
            .padding(.vertical, ChatMetrics.bubblePadV)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            solidBubble(text, time: time, mine: mine, joinsAbove: joinsAbove, joinsBelow: joinsBelow, tail: tail)
        }
    }

    private func solidBubble(_ text: String, time: String, mine: Bool, joinsAbove: Bool, joinsBelow: Bool, tail: Bool) -> some View {
        let glassy = style == .glass && GlassBubbles.offered && !reduceTransparency
        // [bubble-card] A reply on Soft Cards' surface, where a chat draws one.
        let cardy = style == .card && !mine && !Theme.isDesktop && ground != nil
        // Glass takes rounded corners only: no tail, its corner as round as the rest. A card too.
        let outline = BubbleOutline(radius: radius, mine: mine, joinsAbove: joinsAbove, joinsBelow: joinsBelow, tail: tail && !glassy && !cardy)
        let me = meColors
        let colour = mine ? me.fill : Color.hqBotBubble
        let ink = mine ? me.ink : Color.hqLabel
        let timeInk = mine ? me.ink.opacity(0.76) : Color.hqLabel2
        let uiBubble = mine ? me.uiFill : ChatPalette.botBubble
        let uiInk = mine ? me.uiInk : ChatPalette.label
        let increased = contrast == .increased, overPicture = ground != nil
        let glassColour = Color(uiColor: UIColor { traits in
            GlassBubbles.tint(uiBubble.resolvedColor(with: traits), mine: mine,
                              increaseContrast: increased,
                              ink: uiInk.resolvedColor(with: traits),
                              page: HQPalette.page.resolvedColor(with: traits), overPicture: overPicture)
        })
        let shift = ChatMetrics.timeShift(corner: radius)
        return Text("\(Text(text).font(Font.hq(.body)).foregroundStyle(ink))  \(Text(time).font(Font.hq(.caption2)).foregroundStyle(timeInk))")
            .padding(.leading, ChatMetrics.bubblePadH)
            .padding(.trailing, ChatMetrics.bubblePadH + shift)
            .padding(.vertical, ChatMetrics.bubblePadV)
            .background { if cardy { SoftCardBackground(bubbleRadius: radius) } else { tinted(mine: mine, uiBubble: uiBubble, in: outline) } }
            .hqChatBubble(glassy ? glassColour : nil, solid: cardy || tint(mine: mine, uiBubble: uiBubble) != nil ? .clear : colour, in: outline)
            // As wide as the chat lets each side go (`TextLayout.maxBubbleWidth`): a reply the row, yours a short column.
            .frame(maxWidth: mine ? ChatMetrics.userMaxWidth : ChatMetrics.replyMaxWidth, alignment: mine ? .trailing : .leading)
            // Room for the tail, which hangs outside the bubble.
            .padding(mine ? .trailing : .leading, ChatMetrics.tailSize.width)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

extension BubbleCornersPreview {
    /// [tinted-bubbles] The bubble's own copy of the picture, as a chat's bubble draws it (`BubbleShapeView`): nil
    /// unless Tinted is picked (or Card for your own message), Reduce Transparency is off and the preview stands on the chat background.
    private func tint(mine: Bool, uiBubble: UIColor) -> (image: CGImage, aspect: CGSize)? {
        guard style == .tinted || (style == .card && mine), !reduceTransparency, !Theme.isDesktop, ground != nil else { return nil }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = scheme == .dark ? .dark : .light
            traits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
        guard let soft = TintedBubbles.soft(for: traits),
              let image = TintedBubbles.image(soft, picture: Backdrop.chats.picture(for: traits),
                                              bubble: uiBubble, mine: mine,
                                              increaseContrast: contrast == .increased, traits: traits) else { return nil }
        return (image, soft.aspect)
    }

    @ViewBuilder private func tinted(mine: Bool, uiBubble: UIColor, in outline: BubbleOutline) -> some View {
        if let ground, let tint = tint(mine: mine, uiBubble: uiBubble) {
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
    /// High Contrast boxes replies unless Reply Bubbles is off (`ChatCells.swift`).
    var boxedReply = false

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.turnGap + 6) {
            replyPreview
            Text("Thanks!")
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqMeText)
                .padding(.horizontal, ChatMetrics.bubblePadH)
                .padding(.vertical, ChatMetrics.bubblePadV)
                .background(Color.hqMeBubble, in: box(height: 36))
                .overlay(box(height: 36).strokeBorder(Color(uiColor: ChatPalette.meBorder), lineWidth: HQShape.hairline))
                .frame(maxWidth: .infinity, alignment: .trailing)
            textBox
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var replyPreview: some View {
        let text = Text("Your report is ready. It’s in Files, and I can send it to Ivy as well.")
            .font(Font.hq(.body))
            .foregroundStyle(Color.hqLabel)
        if boxedReply {
            let shape = RoundedRectangle(cornerRadius: radius)
            text
                .padding(.horizontal, ChatMetrics.bubblePadH)
                .padding(.vertical, ChatMetrics.bubblePadV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hqBotBubble.opacity(0.5), in: shape)
                .overlay(shape.strokeBorder(Color.hqLabel.opacity(0.12), lineWidth: HQShape.hairline))
        } else {
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .overlay(box(height: 46).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
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
            .font(Font.hqSystem(size: HQFont.legibleLiteral(12 * HQFont.dynamicRatio(nil)), weight: .semibold))
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
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
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
struct ScaleSegments: View {
    var selected: Int
    var pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ThemeState.scalePresets.enumerated()), id: \.element) { index, percent in
                let on = percent == selected
                let last = index == ThemeState.scalePresets.count - 1
                Button { pick(percent) } label: {
                    Text("\(percent)%")
                        .font(Font.hq(.footnote).weight(on && !DeviceWord.isMac ? .semibold : .regular))   // [type] Mac: the fill shows the choice
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
                    HQHairline(axis: .vertical, color: .hqStroke, length: 36)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
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

    private var adaptive: [Skin] { SkinCatalog.all.filter { !$0.hasOneLook } }
    private var darkOnly: [Skin] { SkinCatalog.all.filter { $0.hasOneLook } }

    var body: some View {
        // Not a LazyVGrid: Mac download 479 died "stuck in a recursive layout loop" (self-sizing rows not returning the
        // same size twice) in this page's List a moment after a theme change. A lazy grid sizes by the cards it has made
        // so far; in a List row that height can differ from pass to pass. A dozen cards gain nothing from laziness.
        let count = oneColumn ? 1 : 2
        VStack(alignment: .leading, spacing: 18) {
            group(title: "Adaptive (Light & Dark)", skins: adaptive, count: count)
            if !darkOnly.isEmpty {
                group(title: "Dark Only", skins: darkOnly, count: count)
            }
        }
        // [page-tabs] Its own height whatever the row offers. The List offers the row's height back, and a Grid given a
        // height shrinks its last row to fit (980 pt wanted, 963 then 961 given back, Cyberpunk's taller card spilling
        // out), so the row came out 20 pt taller than the grid and the grid sat 10 pt down in it, under the tabs.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func group(title: String, skins: [Skin], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Font.hq(.caption).weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.hqLabel2)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
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
        }
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
        let radius: CGFloat = desktop ? 4 : 18
        // The card previews the skin as it would draw now (the look, the contrast option and the mode on screen).
        var preview = Theme.shared.state
        preview.skinID = skin.id
        let resolved = ThemeResolver.resolve(preview)
        let tokens = resolved.tokens(dark: dark)
        let previewRadius: CGFloat = desktop ? 3 : 10
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    // Split Light|Dark preview for adaptive skins and bold accent bar on every device (ported from Mac).
                    if skin.onlyModeTag == nil {
                        HStack(spacing: 0) {
                            SkinPreview(tokens: resolved.tokens(dark: false), radius: 0, accentBar: true)
                            SkinPreview(tokens: resolved.tokens(dark: true), radius: 0, accentBar: true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: previewRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: previewRadius, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
                    } else {
                        SkinPreview(tokens: tokens, radius: previewRadius, accentBar: true)
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
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(desktop ? Color.hqPage : Color(uiColor: HQPalette.card)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isSelected ? Color.hqTintText : Color.hqStroke, lineWidth: isSelected ? 2 : HQShape.hairline))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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

    private var compactText: String {
        if DeviceWord.isMac { return text }
        if text == "Dark Only" { return "Dark" }
        if text == "Light Only" { return "Light" }
        return text
    }

    var body: some View {
        // Filled capsule with moon/sun glyph on both Mac and mobile.
        HStack(spacing: 4) {
            Image(systemName: text.hasPrefix("Dark") ? "moon.fill" : "sun.max.fill").imageScale(.small)
            Text(compactText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .font(Font.hq(.caption).weight(.semibold))
        .foregroundStyle(Color.hqLabel)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.hqFill3))
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
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(colour(tokens.meBorder), lineWidth: HQShape.hairline))
                }
                Capsule().fill(colour(tokens.label2)).frame(minWidth: accentBar ? 20 : 84, maxWidth: 84, minHeight: 5, maxHeight: 5)
                RoundedRectangle(cornerRadius: 3).fill(colour(tokens.groupedCard.over(tokens.page)))
                    .frame(height: 14)
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(colour(tokens.separator), lineWidth: HQShape.hairline))
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
    /// [macpass-settings] The iOS look pulls a row in by the capsule's 44 pt touch target. The Mac draws its own push
    /// button there (`hqRowActionButtonStyle`), which has no such target, so pulling in left Copy Link touching the
    /// card's bottom edge.
    static var buttonOverhang: CGFloat { DeviceWord.isMac ? 0 : RowActionButtonStyle.targetOverhang }
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
                    .padding(.vertical, Theme.isDesktop ? 6 : -Self.buttonOverhang)
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
                    .padding(.vertical, Theme.isDesktop ? 0 : -Self.buttonOverhang)
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
