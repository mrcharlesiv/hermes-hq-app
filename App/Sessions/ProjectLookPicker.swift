// [project-look] Visual Icon & Color picker for projects: live pill + badge preview, color swatches, curated one-tap
// Emoji grid + custom emoji input, curated monochrome SF Symbols grid, and one-tap Reset to Default Folder.
// Shared across Project Settings, row/pill menus, the tappable Project Page header icon, and the New Project sheet.

import SwiftUI
import UIKit

/// [project-look] A project's own mark: its emoji (on a tinted disc when colored), its SF Symbol (tinted or on a soft
/// disc when colored), or a folder (tinted when colored).
/// `ink`: the color a mark takes on a selected pill so it never fights the pill's fill (emojis keep their own color).
struct ProjectLookMark: View {
    var look: ProjectLook
    var size: CGFloat = 16
    var ink: Color? = nil
    /// Whether a plain default folder (no emoji, symbol, or color) uses `folder.fill` (true) or `folder` (false).
    var defaultFilled = true

    var body: some View {
        let colour = look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) }
        Group {
            if let emoji = look.emoji {
                Text(emoji)
                    .font(Font.hqSystem(size: HQFont.scaled(size * 0.82)))
                    .frame(width: HQFont.scaled(size + 4), height: HQFont.scaled(size + 4))
                    .background { if let colour { Circle().fill(colour.opacity(0.32)) } }
            } else if let symbol = look.symbol {
                Image(systemName: symbol)
                    .font(Font.hqSystem(size: HQFont.scaled(size * 0.78), weight: .semibold))
                    .foregroundStyle(ink ?? colour ?? Color.hqLabel2)
                    .frame(width: HQFont.scaled(size + 4), height: HQFont.scaled(size + 4))
                    .background { if ink == nil, let colour { Circle().fill(colour.opacity(0.20)) } }
            } else {
                Image(systemName: (defaultFilled || colour != nil) ? "folder.fill" : "folder")
                    .font(Font.hqSystem(size: HQFont.scaled(size * 0.86), weight: .medium))
                    .foregroundStyle(ink ?? colour ?? Color.hqLabel2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Renders a `ProjectLook` into a `UIImage` for UIKit context menus (e.g. Move to Project).
@MainActor enum ProjectLookMenuIcon {
    static func menuAppearance(for look: ProjectLook) -> (image: String?, color: UIColor?, customImage: UIImage?) {
        let uiColor = look.color.map(SessionsOrganizer.uiColor)
        if let emoji = look.emoji {
            return (nil, nil, renderEmoji(emoji, color: uiColor))
        }
        if let symbol = look.symbol {
            return (symbol, uiColor, nil)
        }
        if let uiColor {
            return ("folder.fill", uiColor, nil)
        }
        return ("folder", nil, nil)
    }

    private static func renderEmoji(_ emoji: String, color: UIColor?) -> UIImage {
        let side: CGFloat = 22
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            if let color {
                color.withAlphaComponent(0.28).setFill()
                UIBezierPath(ovalIn: rect).fill()
            }
            let font = HQFont.system(ofSize: color == nil ? 17 : 13.5)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let size = (emoji as NSString).size(withAttributes: attrs)
            let origin = CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
            (emoji as NSString).draw(at: origin, withAttributes: attrs)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

/// Live preview of how the project's badge and Sessions pill appear.
struct ProjectLookPreview: View {
    var name: String
    var look: ProjectLook

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Project" : trimmed
    }

    var body: some View {
        let colour = look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) }
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous)
                    .fill(colour.map { $0.opacity(look.emoji != nil ? 0.24 : 0.16) } ?? Color.hqFill3)
                    .overlay {
                        if Theme.isDesktop {
                            RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous)
                                .strokeBorder(Color(uiColor: HQPalette.stroke), lineWidth: HQShape.hairline)
                        }
                    }
                    .frame(width: HQFont.scaled(48), height: HQFont.scaled(48))
                if let emoji = look.emoji {
                    Text(emoji)
                        .font(Font.hqSystem(size: HQFont.scaled(26)))
                } else if let symbol = look.symbol {
                    Image(systemName: symbol)
                        .font(Font.hqSystem(size: HQFont.scaled(22), weight: .semibold))
                        .foregroundStyle(colour ?? Color.hqLabel)
                } else {
                    Image(systemName: colour != nil ? "folder.fill" : "folder")
                        .font(Font.hqSystem(size: HQFont.scaled(22), weight: .medium))
                        .foregroundStyle(colour ?? Color.hqLabel2)
                }
            }
            .accessibilityHidden(true)

            // Live pill preview matching the Sessions rail.
            HStack(spacing: 6) {
                ProjectLookMark(look: look, size: 15, defaultFilled: false)
                Text(displayName)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: HQFont.scaled(30))
            .background(Capsule().fill(Color(uiColor: HQPalette.sheetCard)))
            .overlay {
                Capsule().strokeBorder(Color(uiColor: HQPalette.separator).opacity(0.6), lineWidth: HQShape.hairline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview: \(displayName), \(look.summaryLabel)")
        .accessibilityIdentifier("project.look.preview")
    }
}

/// Compact color swatch grid (None + 12 `SessionColors`).
struct ProjectLookColorSwatches: View {
    @Binding var color: Int?
    /// Prefix for accessibility identifiers so Project Settings and New Project remain distinct or consistent.
    var identifierPrefix = "sessions.projectSettings.color"

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], alignment: .leading, spacing: 0) {
            swatch(nil)
            ForEach(SessionColors.names.indices, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ index: Int?) -> some View {
        let picked = color == index
        let name = index.flatMap { SessionColors.name($0) } ?? "None"
        return Button {
            Haptics.play(.selection)
            color = index
        } label: {
            ZStack {
                if let index {
                    Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(index))).frame(width: 28, height: 28)
                } else {
                    Circle().strokeBorder(Color.hqLabel3, lineWidth: 1.5).frame(width: 28, height: 28)
                    Image(systemName: "slash.circle").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                }
                if picked { Circle().strokeBorder(Color.hqTint, lineWidth: 2).frame(width: 36, height: 36) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(index.map(String.init) ?? "none")")
    }
}

/// Full visual Icon & Color picker bound to a `ProjectLook`.
struct ProjectLookPickerView: View {
    enum IconStyle: Hashable { case emoji, symbols }

    var projectName: String
    @Binding var look: ProjectLook
    @State private var style: IconStyle
    @State private var emojiText: String

    init(projectName: String, look: Binding<ProjectLook>) {
        self.projectName = projectName
        _look = look
        let initial = look.wrappedValue
        _style = State(initialValue: initial.symbol != nil ? .symbols : .emoji)
        _emojiText = State(initialValue: initial.emoji ?? "")
    }

    private var accentColor: Color {
        look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) } ?? Color.hqTint
    }

    var body: some View {
        List { Group {
            Section {
                ProjectLookPreview(name: projectName, look: look)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    .listRowBackground(Color.clear)
                    .hqDesktopBareRow()
            }

            Section {
                ProjectLookColorSwatches(color: Binding(get: { look.color }, set: { look.color = $0 }))
                    .padding(.vertical, 2)
            } header: { HQSectionLabel { Text("Color") } }

            Section {
                HQSegmentedPicker("Icon Style", options: [("Emoji", IconStyle.emoji), ("Symbols", IconStyle.symbols)], selection: $style)
                    .accessibilityIdentifier("project.look.style")
                    .padding(.vertical, 2)

                if style == .emoji {
                    customEmojiRow
                    emojiGrid
                } else {
                    symbolGrid
                }
            } header: { HQSectionLabel { Text("Icon") } }

            if !look.isEmpty {
                Section {
                    Button {
                        Haptics.play(.selection)
                        look = ProjectLook()
                        emojiText = ""
                    } label: {
                        HStack {
                            Spacer(minLength: 0)
                            Text("Reset to Default Folder")
                                .font(Font.hq(.body).weight(.medium))
                                .foregroundStyle(Color.hqTintText)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: HQFont.scaled(32))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project.look.reset")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .listSectionSpacing(.compact)
        .accessibilityIdentifier("project.look.picker")
        .onChange(of: look.emoji) { _, now in
            let next = now ?? ""
            if emojiText != next { emojiText = next }
        }
    }

    private var customEmojiRow: some View {
        HStack(spacing: 8) {
            Text("Custom").foregroundStyle(Color.hqLabel)
            Spacer(minLength: 12)
            TextField("Emoji", text: $emojiText, prompt: Text("Type emoji"))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .frame(maxWidth: 140)
                .accessibilityIdentifier("sessions.projectSettings.emoji")
                .onChange(of: emojiText) { was, typed in
                    let one = ProjectLook.oneEmoji(typed, replacing: was) ?? ""
                    if one != typed { emojiText = one; return }
                    let next = one.isEmpty ? nil : one
                    guard look.emoji != next else { return }
                    look.emoji = next
                    if next != nil { look.symbol = nil }
                }
            if !emojiText.isEmpty {
                Button {
                    Haptics.play(.selection)
                    emojiText = ""
                    look.emoji = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.hq(.body))
                        .foregroundStyle(Color.hqLabel3)
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear Icon")
                .accessibilityIdentifier("sessions.projectSettings.emojiClear")
            }
            #if targetEnvironment(macCatalyst)
            Button {
                UIApplication.shared.sendAction(NSSelectorFromString("orderFrontCharacterPalette:"), to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: "face.smiling")
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel2)
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open Emoji Picker (⌃⌘Space)")
            .accessibilityLabel("Open Emoji Picker")
            .accessibilityIdentifier("project.look.macEmojiPicker")
            #endif
        }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(44)), spacing: 8)], spacing: 8) {
            ForEach(Array(ProjectLook.emojis.enumerated()), id: \.offset) { index, item in
                let chosen = look.emoji == item
                Button {
                    Haptics.play(.selection)
                    if chosen {
                        look.emoji = nil
                        emojiText = ""
                    } else {
                        look.emoji = item
                        look.symbol = nil
                        emojiText = item
                    }
                } label: {
                    Text(item)
                        .font(Font.hqSystem(size: HQFont.scaled(22)))
                        .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(chosen ? accentColor.opacity(0.22) : Color.hqFill3))
                        .overlay {
                            if chosen {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("project.look.emoji.\(index)")
            }
        }
        .padding(.vertical, 6)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: HQFont.scaled(44)), spacing: 8)], spacing: 8) {
            ForEach(ProjectLook.symbols, id: \.name) { item in
                let chosen = look.symbol == item.name
                let glyphColor: Color = chosen ? .white : (look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) } ?? Color.hqLabel)
                Button {
                    Haptics.play(.selection)
                    if chosen {
                        look.symbol = nil
                    } else {
                        look.symbol = item.name
                        look.emoji = nil
                        emojiText = ""
                    }
                } label: {
                    Image(systemName: item.name)
                        .font(Font.hq(.title3).weight(.medium))
                        .foregroundStyle(glyphColor)
                        .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(chosen ? accentColor : Color.hqFill3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("project.look.symbol.\(item.name)")
            }
        }
        .padding(.vertical, 6)
    }
}

/// Store-backed wrapper that saves every change immediately (no Save button), matching `ProjectSettingsPage`.
struct StoreProjectLookPickerView: View {
    let project: String
    let projectName: String
    let store: SessionStore
    var onChange: () -> Void = {}

    @State private var look: ProjectLook

    init(project: String, projectName: String, store: SessionStore, onChange: @escaping () -> Void = {}) {
        self.project = project
        self.projectName = projectName
        self.store = store
        self.onChange = onChange
        _look = State(initialValue: store.projectLook(project))
    }

    var body: some View {
        ProjectLookPickerView(projectName: projectName, look: Binding(get: { look }, set: { next in
            look = next
            store.setProjectLook(project, next)
            onChange()
        }))
    }
}
