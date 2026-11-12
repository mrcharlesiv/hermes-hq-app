// [app-icons] Settings › Appearance › App Icon: every icon in `AppIconChoice.all` as the Home Screen draws it (the
// built icon in the icon's own rounded mask), the one worn now ticked. A tap asks iOS for it; iOS says so in its own
// alert. On the Mac the Dock takes it at once (`MacDockIcon`).
// [icon-look] Above them, Look: System (the icon follows the Home Screen's light and dark; "System" as Appearance says
// it), or Light or Dark pinned. The grid shows the icons in the look picked (System: the page's).

import SwiftUI

struct AppIconPage: View {
    @State private var current = AppIcons.worn.choice
    @State private var look = AppIcons.worn.look
    @State private var refusal: String?
    /// Changes asked of iOS and not answered yet.
    @State private var picking = 0
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 68
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List { Group {
            Section {
                HQSegmentedPicker("Look", options: AppIconLook.allCases.map { (title: $0.title, value: $0) },
                                  selection: Binding(get: { look }, set: { new in pickLook(new) }), ticks: false)   // `pick` ticks
                    .accessibilityIdentifier("app-icon.look")
            } header: { HQSectionLabel {
                Text("Look")
            } } footer: {
                HQSectionFooter {
                    Text(lookFooter)
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSide + 18, maximum: iconSide + 40), spacing: 12, alignment: .top)],
                          alignment: .center, spacing: 18) {
                    ForEach(AppIconChoice.all) { choice in
                        tile(choice)
                    }
                }
                .padding(.vertical, 12)
            } footer: {
                HQSectionFooter {
                    Text(DeviceWord.isMac
                         ? "Shapes, Matrix and Robot are Hermes’s own faces, drawn by the app. The Dock shows your icon while Hermes HQ is open; Finder and Launchpad keep the Hermes icon."
                         : "Shapes, Matrix and Robot are Hermes’s own faces, drawn by the app.")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .alert("Couldn’t Change the Icon", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
        #if DEBUG
        .task { await AppIconDemo.run { await pick($0, look: $1) } }
        #endif
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let chosen = choice == current
        return Button {
            Task { await pick(choice, look: look) }
        } label: {
            VStack(spacing: 8) {
                AppIconPreview(choice: choice, side: iconSide, look: look)
                    .overlay(alignment: .bottomTrailing) {
                        if chosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: iconSide * 0.3, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.hqTint)
                                .background(Circle().fill(Color.hqGroupedCard).padding(-2.5))
                                .offset(x: iconSide * 0.08, y: iconSide * 0.08)
                                .transition(.hqMotion(.scale(scale: 0.6).combined(with: .opacity)))
                        }
                    }
                // [mac] Mac polish #100: a long name ("Black & White") wraps onto a second line at the others' size; it was
                // shrunk to about three quarters of it to fit one. iPhone and iPad keep one line.
                Text(choice.title)
                    .font(Font.hq(.footnote).weight(chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? Color.hqLabel : Color.hqLabel2)
                    .lineLimit(DeviceWord.isMac ? 2 : 1)
                    .minimumScaleFactor(DeviceWord.isMac ? 1 : 0.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: DeviceWord.isMac)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("app-icon.\(choice.id)")
    }

    private var lookFooter: String {
        let device = DeviceWord.isMac ? "Mac" : DeviceWord.name
        let place = DeviceWord.isMac ? "The Dock icon" : "Your icon"
        switch look {
        case .automatic: return "\(place) turns light or dark with your \(device)."
        case .light: return "\(place) stays light, even when your \(device) is dark."
        case .dark: return "\(place) stays dark, even when your \(device) is light."
        }
    }

    private func pickLook(_ new: AppIconLook) {
        Task { await pick(current, look: new) }
    }

    /// The tick and the look move at once: iOS answers only after its own alert is dismissed. A refusal puts them back.
    private func pick(_ choice: AppIconChoice, look newLook: AppIconLook) async {
        guard choice != current || newLook != look else { return }
        Haptics.play(.selection)
        HQMotion.withAnimation(.snappy) { current = choice; look = newLook }
        picking += 1
        let error = await AppIcons.use(choice, look: newLook)
        picking -= 1
        if error != nil {
            // Back to what iOS wears, once no other change is waiting on its answer (a quick second tap's own answer
            // decides then: putting back the tick from before this tap could undo that one).
            if picking == 0 { HQMotion.withAnimation(.snappy) { (current, look) = AppIcons.worn } }
            // iOS's own words are a system error's ("The operation couldn’t be completed…"), not a reason.
            Haptics.play(.error)
            refusal = "iOS didn’t change the icon. Try again in a moment."
        }
    }
}

/// An icon as the Home Screen draws it: the built picture in the icon's rounded square with a hairline edge (a light
/// icon on a light page otherwise has no edge at all). Automatic: in the page's look.
struct AppIconPreview: View {
    let choice: AppIconChoice
    let side: CGFloat
    var look: AppIconLook = .automatic
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        Group {
            if let image = AppIcons.picture(choice, dark: look.isDark(onDark: scheme == .dark), pixels: Int((side * scale).rounded(.up))) {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Color.hqLabel2.opacity(0.2)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.hqStroke, lineWidth: 0.5))
    }
}

#if DEBUG
/// `-HQDebugAppIcon 1`: the page wears each icon in turn; `-HQDebugAppIcon <icon set name>` picks that one, pinned
/// when the name says so ("AppIcon-Feather-Dark") (clips).
enum AppIconDemo {
    @MainActor static func run(_ pick: @escaping (AppIconChoice, AppIconLook) async -> Void) async {
        let flag = UserDefaults.standard.string(forKey: "HQDebugAppIcon")
        // An icon's name picks just that one: iOS's "You have changed the icon" alert blocks the next switch, so a
        // recording takes one switch per launch.
        if let flag, AppIconChoice.allSetNames.contains(flag) {
            try? await Task.sleep(for: .seconds(1.2))
            let (one, look) = AppIconChoice.worn(named: flag)
            await pick(one, look)
            return
        }
        guard flag == "1" else { return }
        for choice in AppIconChoice.all.dropFirst() + [AppIconChoice.all[0]] {
            try? await Task.sleep(for: .seconds(2.2))
            Task { await pick(choice, .automatic) }
        }
    }
}
#endif
