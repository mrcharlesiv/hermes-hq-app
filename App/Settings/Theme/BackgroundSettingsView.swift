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
        }
    }

    static var rowsNote: String { "A picture behind the app’s pages, and one behind chats, or the same for both. The Desktop Look keeps its plain pages. \(DeviceWord.onlyHere)" }
    static var appNote: String { "Behind Sessions, Bots, Jobs, More, Settings and the pages they open. Dim covers it with the page colour, so the rows on it stay easy to read. \(DeviceWord.onlyHere)" }
    static var chatNote: String { "Behind every chat. Dim covers it with the page colour, so the grey lines between messages stay easy to read. \(DeviceWord.onlyHere)" }
    static let sameNote = "Chats show the app’s picture, with their own Dim and Blur."
    /// Added under the preview while the Desktop Look is on, which keeps its plain pages.
    static let desktopNote = "The Desktop Look is on, so it shows once you turn that off."
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
                    Image(systemName: "photo").font(Font.hqSystem(size: 11)).foregroundStyle(Color.hqLabel3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 0.5))
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

struct BackgroundPage: View {
    var place: Backdrop.Place
    @State private var busy = false
    @State private var draftDim: Double?
    @State private var dragging = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var backdrop: Backdrop { place == .app ? .app : .chats }

    var body: some View {
        let dim = Int((draftDim ?? Double(backdrop.dim)).rounded())
        ScrollViewReader { proxy in
        List { Group {
            Section {
                BackdropPreview(place: place, dim: dim)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("theme.backgroundPreview")
            } footer: { HQSectionFooter {
                let note = place == .app ? BackdropWords.appNote : BackdropWords.chatNote
                Text(Theme.isDesktop ? note + " " + BackdropWords.desktopNote : note)
            } }
            if place == .chats, Backdrop.app.source != nil {
                Section {
                    Toggle(isOn: Binding(get: { backdrop.sameAsApp }, set: { on in
                        Haptics.play(.selection)
                        backdrop.setSameAsApp(on)
                    })) {
                        Text("Use App Background").foregroundStyle(Color.hqLabel)
                    }
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("theme.backgroundSame")
                } footer: { HQSectionFooter {
                    Text(BackdropWords.sameNote)
                } }
            }
            if !backdrop.followsApp {
                ForEach(BackdropPreset.Group.allCases, id: \.self) { group in
                    Section {
                        BackdropGrid(place: place, group: group, busy: busy, columns: columns) { source in
                            pick(source)
                        } pickPhoto: { from in
                            BackdropPicker.pick(from, for: place) { busy = $0 }
                        }
                        .padding(.vertical, 6)
                    } header: { HQSectionLabel {
                        Text(group.title)
                    } }
                    .id(group)
                }
            }
            if backdrop.drawn != nil {
                Section {
                    dimRow(dim)
                        .hqRowPadding(4)
                    Toggle(isOn: Binding(get: { backdrop.blur }, set: { backdrop.setBlur($0) })) {
                        Text("Blur").foregroundStyle(Color.hqLabel)
                    }
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("theme.backgroundBlur")
                }
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .animation(HQMotion.reduced ? nil : .default, value: backdrop.followsApp)
        #if DEBUG
        .onAppear {
            // `-HQDebugBackgroundGroup photographic|illustrated|painted|doodles` (screenshots): open scrolled to that group.
            guard let name = UserDefaults.standard.string(forKey: "HQDebugBackgroundGroup"),
                  let group = BackdropPreset.Group.allCases.first(where: { "\($0)" == name }) else { return }
            Task { @MainActor in proxy.scrollTo(group, anchor: .top) }
        }
        #endif
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
        }
        HQAnnounce.say("\(BackdropWords.title(place)): \(BackdropWords.name(source)).")
    }

    private func dimRow(_ dim: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dim").foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text("\(dim)%").monospacedDigit().foregroundStyle(Color.hqLabel2)
            }
            .accessibilityHidden(true)   // the slider says both
            Slider(value: Binding(get: { draftDim ?? Double(backdrop.dim) }, set: { value in
                if Int(value.rounded()) / 10 != dim / 10 { Haptics.play(.selection) }
                draftDim = value
                // VoiceOver's swipes and the Mac's arrow keys move it without a drag: those apply at once.
                if !dragging { finishDim() }
            // No `step`: iOS 26 draws a dot under the track for every step. The value is rounded instead.
            }), in: Double(Backdrop.dimRange.lowerBound)...Double(Backdrop.dimRange.upperBound)) {
                Text("Dim")
            } minimumValueLabel: {
                Image(systemName: "sun.max").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "sun.min").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            } onEditingChanged: { editing in
                dragging = editing
                if !editing { finishDim() }
            }
            .tint(Color.hqTint)
            .accessibilityValue("\(dim) percent")
            .accessibilityIdentifier("theme.backgroundDim")
        }
    }

    private func finishDim() {
        guard let draftDim else { return }
        self.draftDim = nil
        backdrop.setDim(Int(draftDim.rounded()))
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
    @Environment(\.colorScheme) private var scheme

    private enum Item: Hashable { case none, preset(BackdropPreset), photo }
    private var items: [Item] {
        let pictures = group.presets.map(Item.preset)
        return group == .classic ? [.none] + pictures + [.photo] : pictures
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
                    BackdropTilePicture(source: .preset(preset), folder: nil, traits: traits)
                }
            }
            .buttonStyle(.plain)
            .modifier(TileTraits(name: preset.label, selected: selected, id: "\(place.rawValue).\(preset.rawValue)"))
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
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 0.5))
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
        let picture = BackdropPicture(kind: .preset(preset, dark: traits.userInterfaceStyle == .dark, accent: BackdropPicture.accent(preset, traits),
                                                    width: Self.size.width, height: Self.size.height), blur: false)
        if let image = made[picture] { return image }
        guard !making.contains(picture) else { return nil }
        making.insert(picture)
        Task {
            let image = await Task.detached(priority: .userInitiated) { picture.make() }.value
            making.remove(picture)
            if let image { made[picture] = image }
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
                AppRowsPreview()
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
                                         ground: image == nil || size == .zero ? nil : ChatGround(size: size))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
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

/// Three rows as the Bots list draws them: a face, a name, a line of the last reply, a time.
private struct AppRowsPreview: View {
    private static let rows: [(name: String, line: String, time: String, hue: Color)] = [
        ("Research", "The three reports are summarised in Files.", "9:41", .blue),
        ("Finance", "Paid the invoices due this week.", "9:12", .green),
        ("Writer", "Here’s a second draft of the post.", "8:05", .orange),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows, id: \.name) { row in
                HStack(spacing: 12) {
                    Circle().fill(row.hue.gradient).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                            Spacer(minLength: 8)
                            Text(row.time).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                        Text(row.line).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}
