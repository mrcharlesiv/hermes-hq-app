// [backdrop] Theme › Backgrounds (owner 2026-11-01: "one background on all of the app and then a separate background for
// chats. Or I can have them be the same"): two rows, App Background and Chat Background, each opening its own page. A
// page has a preview, the pictures to pick from (None, the app's own in their groups, Your Photo), then Dim and Blur.
// Chat Background starts with Use App Background. iOS look only, as the backgrounds are (App/Theme/Backdrop.swift).
// [theme-pages] Owner 2026-11-03: the two rows are Settings › Appearance › Backgrounds, a page of their own, not a tab
// on the Theme page.

import SwiftUI
import UIKit

enum BackdropWords {
    static func title(_ place: Backdrop.Place) -> String { place == .app ? "App Background" : "Chat Background" }

    /// The value a background's row shows: what the place draws.
    @MainActor static func value(_ place: Backdrop.Place) -> String {
        value(of: place == .app ? Backdrop.app : Backdrop.chats)
    }

    @MainActor static func value(of backdrop: Backdrop) -> String {
        if backdrop.followsApp { return "Same as App" }
        return name(backdrop.chosen)
    }

    static func name(_ source: Backdrop.Source?) -> String {
        switch source {
        case nil: "None"
        case .preset(let preset): preset.label
        case .photo: "Your Photo"
        case .color: "Custom Color"
        }
    }

    /// Concise summary shown on Appearance › Backgrounds (nil when both are None).
    @MainActor static var summary: String? {
        if Backdrop.app.drawn != nil { return value(of: .app) }
        if Backdrop.chats.drawn != nil { return value(of: .chats) }
        return nil
    }

    static var rowsNote: String { "A picture behind the app’s pages, and one behind chats, or the same for both. The Hermes Look keeps its plain pages. \(DeviceWord.onlyHere)" }
    static var appNote: String { "Behind Sessions, Bots, Jobs, More, Settings and the pages they open. Wash blends the page color over it so rows stay readable. \(DeviceWord.onlyHere)" }
    static var chatNote: String { "Behind every chat. Wash blends the page color over it so text and dividers stay readable. \(DeviceWord.onlyHere)" }
    /// [backdrop-cards]
    static let cardsNote = "Cards lay a theme-matched backing behind each list so text stays readable. With Reduce Transparency on, Glass cards are solid."
    static let sameNote = "Chats show the app’s picture, with their own Wash and Blur."
    /// Added under the preview while the Hermes Look is on, which keeps its plain pages.
    static let desktopNote = "The Hermes Look is on, so it shows once you switch back to Native."
}

/// [theme-pages] Settings › Appearance › Backgrounds: the two rows, each opening its page.
enum BackgroundsSettings {
    static func make() -> UIViewController {
        let opener = BackgroundOpener()
        let page = SettingsPageController(title: "Backgrounds", BackgroundsSettingsView(opener: opener))
        opener.host = page
        page.view.accessibilityIdentifier = "settings.backgrounds"
        page.view.backgroundColor = HQPalette.page
        return page
    }

    /// A search for one background: its page, over Backgrounds, so Back goes to the two rows.
    static func make(opening place: Backdrop.Place) -> [UIViewController] {
        [make(), BackgroundPageController.make(place)]
    }
}

struct BackgroundsSettingsView: View {
    var opener: BackgroundOpener
    #if DEBUG
    private static var debugOpened = false
    #endif

    var body: some View {
        List { Group {
            Section {
                BackgroundRows { place in opener.open(place) }
            } footer: { HQSectionFooter {
                Text(BackdropWords.rowsNote)
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        #if DEBUG
        .onAppear {
            // `-HQDebugOpenBackground app|chats` (screenshots): that page opened over this one.
            guard !Self.debugOpened, let place = UserDefaults.standard.string(forKey: "HQDebugOpenBackground")
                .flatMap(Backdrop.Place.init(rawValue:)) else { return }
            Self.debugOpened = true
            Task { @MainActor in opener.open(place) }
        }
        #endif
    }
}

/// The two rows on Backgrounds.
struct BackgroundRows: View {
    var open: (Backdrop.Place) -> Void

    var body: some View {
        // Read so the rows follow a change made on a pushed page.
        let _ = (Backdrop.app.revision, Backdrop.chats.revision)
        ForEach([Backdrop.Place.app, .chats], id: \.self) { place in
            Button { open(place) } label: {
                HStack(spacing: 12) {
                    BackdropThumb(place: place)
                        .frame(width: HQFont.scaled(22), height: HQFont.scaled(36))   // [ui-sizing] × UI Scale, as the row
                    Text(BackdropWords.title(place)).foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 16)
                    Text(BackdropWords.value(place)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BackdropWords.title(place))
            .accessibilityValue(BackdropWords.value(place))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("theme.background.\(place.rawValue)")
        }
    }
}

/// The small picture at the head of a row: what the place draws, or the page colour.
private struct BackdropThumb: View {
    var place: Backdrop.Place
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let backdrop = place == .app ? Backdrop.app : Backdrop.chats
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(backdrop.drawn?.source == nil ? Color.hqFill3 : Color.hqPage)
            .overlay {
                if let source = backdrop.drawn?.source {
                    BackdropTilePicture(source: source, folder: backdrop.drawn?.folder, traits: traits)
                } else {
                    // [ui-sizing 2026-11-09] None: a quiet tile with a picture glyph. The bare page colour read as a
                    // small black block, as if the picture had failed to load.
                    Image(systemName: "photo").font(Font.hqSystem(size: HQFont.legibleLiteral(11))).foregroundStyle(Color.hqLabel3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.line(0.5)))
            .accessibilityHidden(true)
    }
}

// MARK: - The page

enum BackgroundPageController {
    static func make(_ place: Backdrop.Place) -> UIViewController {
        let page = SettingsPageController(title: BackdropWords.title(place), BackgroundPage(place: place))
        page.view.accessibilityIdentifier = "settings.background.\(place.rawValue)"
        return page
    }
}

/// Unified 4-way Soft Cards mode (`Off | Tinted | Glass | Solid`) for App Background.
private enum CardChoice: String, Hashable, CaseIterable {
    case off, tinted, glass, solid

    var title: String {
        switch self {
        case .off: "Off"
        case .tinted: "Tinted"
        case .glass: "Glass"
        case .solid: "Solid"
        }
    }

    var caption: String {
        switch self {
        case .off: "Text straight on wallpaper"
        case .tinted: "Soft theme-tinted blur"
        case .glass: "Liquid Glass cards"
        case .solid: "Opaque theme cards"
        }
    }

    static func current(for backdrop: Backdrop) -> CardChoice {
        guard backdrop.cards else { return .off }
        return switch backdrop.cardStyle {
        case .tinted: .tinted
        case .glass: .glass
        case .solid: .solid
        }
    }
}

struct BackgroundPage: View {
    var place: Backdrop.Place
    @State private var busy = false
    @State private var draftDim: Double?
    @State private var dragging = false
    @State private var selectedGroup: BackdropPreset.Group = .classic
    @State private var syncedInitialGroup = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var backdrop: Backdrop { place == .app ? .app : .chats }

    var body: some View {
        let _ = (backdrop.revision, Backdrop.app.revision)
        let dim = Int((draftDim ?? Double(backdrop.dim)).rounded())
        let side: CGFloat = DeviceWord.isMac ? 20 : 16
        VStack(spacing: 0) {
            // Pinned preview + live Wash / Blur / Cards strip so every adjustment is visible in real time.
            VStack(spacing: 10) {
                BackdropPreview(place: place, dim: dim)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
                    .accessibilityIdentifier("theme.backgroundPreview")

                if backdrop.drawn != nil {
                    controlsCard(dim: dim)
                }

                if place == .chats, Backdrop.app.source != nil {
                    Toggle(isOn: Binding(get: { backdrop.sameAsApp }, set: { on in
                        Haptics.play(.selection)
                        backdrop.setSameAsApp(on)
                    })) {
                        Text("Use App Background").foregroundStyle(Color.hqLabel)
                    }
                    .tint(Color.hqTint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("theme.backgroundSame")
                }

                if !backdrop.followsApp {
                    categoryChips
                }
            }
            .padding(.horizontal, side)
            .padding(.top, 8)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if backdrop.followsApp {
                        Text(BackdropWords.sameNote)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .padding(.horizontal, 4)
                    } else {
                        BackdropGrid(place: place, group: selectedGroup, busy: busy, columns: columns) { source in
                            pick(source)
                        } pickPhoto: { from in
                            BackdropPicker.pick(from, for: place) { busy = $0 }
                        } pickColor: { current in
                            BackdropColorPicker.present(for: place, initial: current)
                        }
                        .padding(12)
                        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if Theme.isDesktop {
                        Text(BackdropWords.desktopNote)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, side)
                .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: HQPalette.groupedPage).ignoresSafeArea())
        .hqMacForm(settings: true)
        .animation(HQMotion.reduced ? nil : .default, value: backdrop.followsApp)
        .onAppear {
            guard !syncedInitialGroup else { return }
            syncedInitialGroup = true
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "HQDebugBackgroundGroup"),
               let group = BackdropPreset.Group.allCases.first(where: { "\($0)" == name }) {
                selectedGroup = group
                return
            }
            #endif
            if case .preset(let preset) = backdrop.chosen,
               let group = BackdropPreset.Group.allCases.first(where: { $0.presets.contains(preset) }) {
                selectedGroup = group
            } else if case .color = backdrop.chosen {
                selectedGroup = .solids
            }
        }
    }

    private func controlsCard(dim: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Compact Wash slider + Blur pill in one row.
            HStack(spacing: 10) {
                Text("Wash")
                    .font(Font.hq(.subheadline).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                Slider(value: Binding(get: { draftDim ?? Double(backdrop.dim) }, set: { value in
                    if Int(value.rounded()) / 10 != dim / 10 { Haptics.play(.selection) }
                    draftDim = value
                    if !dragging { finishDim() }
                }), in: Double(Backdrop.dimRange.lowerBound)...Double(Backdrop.dimRange.upperBound)) {
                    Text("Wash")
                } onEditingChanged: { editing in
                    dragging = editing
                    if !editing { finishDim() }
                }
                .tint(Color.hqTint)
                .accessibilityLabel("Wash")
                .accessibilityValue("\(dim) percent")
                .accessibilityIdentifier("theme.backgroundDim")

                Text("\(dim)%")
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityHidden(true)

                if !backdrop.drawnIsSolid {
                    Button {
                        Haptics.play(.selection)
                        backdrop.setBlur(!backdrop.blur)
                    } label: {
                        Text("Blur")
                            .font(Font.hq(.footnote).weight(.semibold))
                            .foregroundStyle(backdrop.blur ? Color.hqOnTint : Color.hqLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(backdrop.blur ? Color.hqTint : Color.hqFill3, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Blur")
                    .accessibilityAddTraits(backdrop.blur ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("theme.backgroundBlur")
                }
            }

            // Unified 1-row Cards picker (Off | Tinted | Glass | Solid) on App Background.
            if place == .app {
                let choice = CardChoice.current(for: backdrop)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cards")
                            .font(Font.hq(.subheadline).weight(.medium))
                            .foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 8)
                        Text(choice.caption)
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("theme.backgroundCardStyleLine")
                    }
                    HQSegmentedPicker("Cards", options: CardChoice.allCases.map { ($0.title, $0) },
                                      selection: Binding(get: { choice }, set: { next in
                                          guard next != choice else { return }
                                          Haptics.play(.selection)
                                          switch next {
                                          case .off:
                                              backdrop.setCards(false)
                                          case .tinted:
                                              backdrop.setCards(true)
                                              backdrop.setCardStyle(.tinted)
                                          case .glass:
                                              backdrop.setCards(true)
                                              backdrop.setCardStyle(.glass)
                                          case .solid:
                                              backdrop.setCards(true)
                                              backdrop.setCardStyle(.solid)
                                          }
                                      }), ticks: false, wholeLabels: true)
                        .labelsHidden()
                        .accessibilityIdentifier("theme.backgroundCards")
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BackdropPreset.Group.allCases, id: \.self) { group in
                    let on = group == selectedGroup
                    Button {
                        guard !on else { return }
                        Haptics.play(.selection)
                        selectedGroup = group
                    } label: {
                        Text(group.shortTitle)
                            .font(Font.hq(.footnote).weight(.semibold))
                            .foregroundStyle(on ? Color.hqOnTint : Color.hqLabel2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(on ? Color.hqTint : Color(uiColor: HQPalette.card), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.title)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("theme.backgroundCategory.\(group)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var columns: Int {
        if typeSize.isAccessibilitySize { return 3 }
        return DeviceWord.isMac ? 6 : 4
    }

    private func pick(_ source: Backdrop.Source?) {
        Haptics.play(.selection)
        switch source {
        case nil: backdrop.clear()
        case .preset(let preset): backdrop.setPreset(preset)
        case .photo: break   // a photo is chosen through its menu
        case .color(let hex): backdrop.setColor(hex)
        }
        HQAnnounce.say("\(BackdropWords.title(place)): \(BackdropWords.name(source)).")
    }

    private func finishDim() {
        guard let draftDim else { return }
        self.draftDim = nil
        backdrop.setDim(Int(draftDim.rounded()))
    }
}

private extension BackdropPreset.Group {
    var shortTitle: String {
        switch self {
        case .classic: "Classic"
        case .solids: "Solids"
        case .photographic: "Photo"
        case .illustrated: "Illustrated"
        case .painted: "Painted"
        case .doodles: "Doodles"
        }
    }
}

// MARK: - The pictures to pick from

/// One group of the app's pictures in rows of `columns`, the first group between None and Your Photo. Not a LazyVGrid:
/// in a List row a lazy grid's height can differ from pass to pass (the Mac 479 layout loop on this same page).
private struct BackdropGrid: View {
    var place: Backdrop.Place
    var group: BackdropPreset.Group
    var busy: Bool
    var columns: Int
    var pick: (Backdrop.Source?) -> Void
    var pickPhoto: (BackdropPicker.Source) -> Void
    var pickColor: (UInt32?) -> Void
    @Environment(\.colorScheme) private var scheme

    private enum Item: Hashable { case none, preset(BackdropPreset), photo, color }
    private var items: [Item] {
        let pictures = group.presets.map(Item.preset)
        switch group {
        case .classic: return [.none] + pictures + [.photo]
        case .solids: return pictures + [.color]
        default: return pictures
        }
    }

    var body: some View {
        let backdrop = place == .app ? Backdrop.app : Backdrop.chats
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let items = self.items
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 14) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(start..<start + columns, id: \.self) { index in
                        if index < items.count {
                            tile(items[index], backdrop: backdrop, traits: traits)
                        } else {
                            Color.clear.frame(height: 0)   // a short last row keeps its tiles one column wide
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func tile(_ item: Item, backdrop: Backdrop, traits: UITraitCollection) -> some View {
        switch item {
        case .none:
            Button { pick(nil) } label: {
                BackdropTile(name: "None", selected: backdrop.chosen == nil) {
                    ZStack {
                        Color.hqPage
                        Image(systemName: "circle.slash").font(Font.hq(.title3)).foregroundStyle(Color.hqLabel2)
                    }
                }
            }
            .buttonStyle(.plain)
            .modifier(TileTraits(name: "None", selected: backdrop.chosen == nil, id: "\(place.rawValue).none"))
        case .preset(let preset):
            let selected = backdrop.chosen == .preset(preset)
            Button { pick(.preset(preset)) } label: {
                BackdropTile(name: preset.label, selected: selected) {
                    ZStack {
                        BackdropTilePicture(source: .preset(preset), folder: nil, traits: traits)
                        if preset == .solidTint {
                            Image(systemName: "paintpalette.fill")
                                .font(Font.hq(.title3))
                                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.68) : Color.black.opacity(0.42))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .modifier(TileTraits(name: preset.label, selected: selected, id: "\(place.rawValue).\(preset.rawValue)"))
        case .color:
            let customHex: UInt32? = if case .color(let hex) = backdrop.chosen { hex } else { nil }
            Button {
                Haptics.play(.selection)
                pickColor(customHex)
            } label: {
                BackdropTile(name: "Custom", selected: customHex != nil) {
                    ZStack {
                        if let customHex {
                            BackdropTilePicture(source: .color(customHex), folder: nil, traits: traits)
                        } else {
                            AngularGradient(
                                colors: [
                                    Color(red: 0.88, green: 0.48, blue: 0.48),
                                    Color(red: 0.89, green: 0.72, blue: 0.45),
                                    Color(red: 0.53, green: 0.77, blue: 0.55),
                                    Color(red: 0.42, green: 0.71, blue: 0.81),
                                    Color(red: 0.60, green: 0.53, blue: 0.85),
                                    Color(red: 0.85, green: 0.49, blue: 0.70),
                                    Color(red: 0.88, green: 0.48, blue: 0.48),
                                ],
                                center: .center
                            )
                            Circle()
                                .fill(Color.black.opacity(0.38))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(Font.hq(.callout).weight(.semibold))
                                        .foregroundStyle(Color.white)
                                }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .modifier(TileTraits(name: customHex == nil ? "Custom" : "Custom Color, choose another", selected: customHex != nil,
                                 id: "\(place.rawValue).color"))
        case .photo:
            let photo: Backdrop.Source? = if case .photo = backdrop.chosen { backdrop.chosen } else { nil }
            Menu {
                Button { pickPhoto(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    .accessibilityIdentifier("theme.backgroundLibrary")
                Button { pickPhoto(.file) } label: { Label("Choose File", systemImage: "folder") }
                    .accessibilityIdentifier("theme.backgroundFile")
            } label: {
                BackdropTile(name: "Your Photo", selected: photo != nil) {
                    ZStack {
                        if let photo {
                            BackdropTilePicture(source: photo, folder: backdrop.folder, traits: traits)
                        } else {
                            Color.hqPage
                            Image(systemName: "photo.badge.plus").font(Font.hq(.title3)).foregroundStyle(Color.hqTintText)
                        }
                        if busy { ProgressView().accessibilityLabel("Reading the picture") }
                    }
                }
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .disabled(busy)
            .modifier(TileTraits(name: photo == nil ? "Your Photo" : "Your Photo, choose another", selected: photo != nil,
                                 id: "\(place.rawValue).photo"))
        }
    }
}

private struct TileTraits: ViewModifier {
    var name: String
    var selected: Bool
    var id: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("theme.backgroundTile.\(id)")
    }
}

/// A phone-shaped picture with its name under it; the chosen one ringed in the accent with a check.
private struct BackdropTile<Face: View>: View {
    var name: String
    var selected: Bool
    @ViewBuilder var face: Face
    private static var radius: CGFloat { Theme.isDesktop ? 4 : 10 }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay { face }
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.line(0.5)))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                    .strokeBorder(selected ? Color.hqTintText : Color.clear, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Font.hq(.body))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.hqOnTint, Color.hqTintText)
                            .padding(7)
                    }
                }
            Text(name)
                .font(Font.hq(.caption))
                .foregroundStyle(selected ? Color.hqLabel : Color.hqLabel2)
                .lineLimit(1)
                .minimumScaleFactor(DeviceWord.isMac ? 1 : 0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A source's picture filling its box: the app's own drawn small for a tile, a photo from the drawn copy.
private struct BackdropTilePicture: View {
    var source: Backdrop.Source
    var folder: URL?
    var traits: UITraitCollection

    var body: some View {
        let image: UIImage? = switch source {
        case .preset(let preset): BackdropThumbs.shared.image(preset, traits: traits)
        case .photo(let name): folder.flatMap { BackdropImages.shared.image(BackdropPicture(kind: .photo($0.appending(path: name)), blur: false)) }
        case .color(let hex): BackdropThumbs.shared.image(color: hex, traits: traits)
        }
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            Color.hqFill3
        }
    }
}

/// The app's own pictures drawn small (a tile, a row's thumbnail), made off the main thread the first time.
@MainActor @Observable final class BackdropThumbs {
    static let shared = BackdropThumbs()
    private(set) var made: [BackdropPicture: UIImage] = [:]
    @ObservationIgnored private var making: Set<BackdropPicture> = []
    /// 9:16, about a tile's size in pixels on a 3× screen.
    private static let size = (width: 240, height: 426)

    func image(_ preset: BackdropPreset, traits: UITraitCollection) -> UIImage? {
        load(BackdropPicture(kind: .preset(preset, dark: traits.userInterfaceStyle == .dark, accent: BackdropPicture.accent(preset, traits),
                                           width: Self.size.width, height: Self.size.height), blur: false))
    }

    func image(color hex: UInt32, traits: UITraitCollection) -> UIImage? {
        load(BackdropPicture(kind: .color(hex, dark: traits.userInterfaceStyle == .dark, width: Self.size.width, height: Self.size.height), blur: false))
    }

    private func load(_ picture: BackdropPicture) -> UIImage? {
        if let image = made[picture] { return image }
        guard !making.contains(picture) else { return nil }
        making.insert(picture)
        Task {
            let image = await Task.detached(priority: .userInitiated) { picture.make() }.value
            making.remove(picture)
            if let image {
                if case .color = picture.kind {
                    let oldColors = made.keys.filter { if case .color = $0.kind { true } else { false } }
                    if oldColors.count > 8 { oldColors.forEach { made[$0] = nil } }
                }
                made[picture] = image
            }
        }
        return nil
    }
}

// MARK: - Previews

/// The page's preview: what the place draws, the page colour over it at Dim, and a list's rows (App) or a chat's
/// messages (Chats) on it.
private struct BackdropPreview: View {
    var place: Backdrop.Place
    var dim: Int
    @Environment(\.colorScheme) private var scheme
    @State private var ready = 0
    @State private var size = CGSize.zero

    var body: some View {
        let backdrop = place == .app ? Backdrop.app : Backdrop.chats
        let _ = (backdrop.revision, Backdrop.app.revision, ready)
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let image = backdrop.image(for: traits)
        // The sample sets the height (240 at least): at the largest text sizes its rows and bubbles grow past 240 and
        // were cut off. The picture fills whatever that is.
        Group {
            if place == .app {
                // [soft-cards] The sample rows on their soft card while Soft Cards is on, as the lists draw them.
                if backdrop.cards, image != nil {
                    AppRowsPreview()
                        .padding(.vertical, BackdropCards.pad)
                        .background(SoftCardBackground())
                        .padding(.horizontal, BackdropCards.side)
                        .padding(.vertical, 12)
                } else {
                    AppRowsPreview()
                }
            } else {
                VStack(spacing: 10) {
                    // On its frosted pill, as a chat on a background draws a day (`ChatBaseCell.placeBacking`).
                    Text("Today")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: .capsule)
                    BubbleCornersPreview(radius: CGFloat(Theme.shared.state.bubbleCorners),
                                         style: BubbleStyles.shown(Theme.shared.state.bubbleStyle),
                                         ground: image == nil || size == .zero ? nil : ChatGround(size: size),
                                         plainReply: Theme.shared.state.plainReplies)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 196)
        .background {
            ZStack {
                Color.hqPage
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                    Color.hqPage.opacity(Double(dim) / 100)
                }
            }
        }
        // [tinted-bubbles] Tinted bubbles show their slice of the picture as it fills this preview.
        .coordinateSpace(.named(ChatGround.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .clipped()
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: Backdrop.pictureReady)) { _ in ready &+= 1 }
    }
}

/// Three rows as the Bots list draws them, with real Hermes bot faces (demo bots Otto, Ivy, Wren).
private struct AppRowsPreview: View {
    private static let rows: [(profile: String, name: String, line: String, time: String)] = [
        ("otto", "Otto", "Drafted release notes for build 1275.", "9:41"),
        ("ivy", "Ivy", "Weekly metrics are saved in Files.", "9:12"),
        ("wren", "Wren", "Here’s the revised onboarding copy.", "8:05"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows, id: \.profile) { row in
                HStack(spacing: 12) {
                    HeadImage(head: Head.defaultHead(profile: row.profile), size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            Text(row.time).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                        Text(row.line).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}
