// Settings › Appearance, regrouped (owner 2026-11-18: "we just kept cramming in new features"). Every look setting,
// grouped by what it changes:
//   Look             Light or Dark, Theme (the themes only), Desktop Look
//   Text Size        UI Scale
//   Chats            Chat Bubbles (the Desktop Look's Corners and Text Box too), Backgrounds; on the Mac, Thinking Bar
//   Bots & Sessions  Density, Chats Under Bots, Working Ring
//   App              Tabs, Top Edge, App Icon
// The Mac's Appearance category draws these groups in its pane. On the iPhone and iPad they are a page of their own
// behind one Appearance row of the Settings list (owner's pick, 2026-11-18).

import SwiftUI
import UIKit

/// The rows a search result can land on that Appearance draws (`row:<id>`).
enum AppearanceRows {
    static let lightOrDark = "row:appearance"
    static let desktopLook = "row:desktop-look"
    static let highContrast = "row:high-contrast"
    static let uiScale = "row:ui-scale"
    static let density = "row:density"
    static let workingRing = "row:working-ring"
    static let topEdge = "row:top-edge"
    static let thinkingBar = "row:thinking-drive"

    /// Whether Appearance draws `row` on this device (Thinking Bar lives in Appearance › Chats on both iOS and Mac).
    static func contains(_ row: String) -> Bool {
        switch row {
        case lightOrDark, desktopLook, highContrast, uiScale, density, workingRing, topEdge, thinkingBar: true
        default: false
        }
    }
}

enum AppearancePage {
    static let title = "Appearance"

    /// `reveal`: a row (`AppearanceRows`) the page scrolls to and marks a moment, as the Settings list marks its own.
    static func make(model: SettingsRootModel, router: SettingsRouter, reveal: String? = nil) -> UIViewController {
        let page = SettingsPageController(title: title, AppearancePageView(model: model, router: router, reveal: reveal))
        page.view.accessibilityIdentifier = "settings.appearance-page"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

struct AppearancePageView: View {
    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    var reveal: String?
    @State private var revealed: String?

    var body: some View {
        ScrollViewReader { proxy in
            List { Group {
                AppearanceSections(model: model, router: router, revealed: revealed)
            }.hqMacSettingsRowInsets() }
            .hqMacForm(settings: true)
            .hqGroupedPage()
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("settings.appearance-list")
            .onAppear { model.refresh() }   // App Icon's value, back from its page
            .task {
                // A beat for the push to land before the list scrolls, then the mark for a moment.
                guard let reveal else { return }
                try? await Task.sleep(for: .milliseconds(350))
                HQMotion.withAnimation { proxy.scrollTo(reveal, anchor: .center) }
                revealed = reveal
                try? await Task.sleep(for: .seconds(1.4))
                revealed = nil
            }
        }
    }
}

/// Appearance's groups, as list sections.
struct AppearanceSections: View {
    enum Part: String {
        case look, size, chats, lists, app

        var title: String {
            switch self {
            case .look: "Look"
            case .size: "Text Size"
            case .chats: "Chats"
            case .lists: "Bots & Sessions"
            case .app: "App"
            }
        }
    }

    @Bindable var model: SettingsRootModel
    let router: SettingsRouter
    /// The row a search result marks.
    var revealed: String?
    @AppStorage(WorkingRing.key) private var workingRing = false   // [ring-off-default]
    @Environment(\.colorSchemeContrast) private var systemContrast
    @State private var confirmReset = false

    private var increaseContrast: Bool { systemContrast == .increased || HQAccessibility.overrides.contrast }

    var body: some View {
        let _ = Theme.touch()
        let _ = (Backdrop.app.revision, Backdrop.chats.revision)
        let state = Theme.shared.state
        look(state)
        size(state)
        chats(state)
        lists(state)
        app(state)
        resetSection
    }

    private func header(_ part: Part) -> some View { HQSectionLabel { Text(part.title) } }

    // MARK: Notes

    static var compactNote: String {
        // [mac] The Mac's bots are in the sidebar, and its rows have one line of preview whatever the density.
        // [desktop-density] The Mac's sidebar is the same at both in the Desktop Look.
        DeviceWord.isMac && Theme.isDesktop ? "Compact fits more on the Sessions page: smaller faces and shorter rows."
        : DeviceWord.isMac
            ? "Compact fits more in the sidebar's bots and on the Sessions page: smaller faces and shorter rows."
            : "Compact fits more on the Bots and Sessions pages: smaller faces, shorter rows and one line of preview."
    }

    private func lookNote(_ state: ThemeState) -> String? {
        let parts = [
            AppearanceSetting.forcedBySkin.map { "\(state.skin.label) has only a \($0 == .dark ? "dark" : "light") look." },
            state.desktopLook ? ThemeContrast.switchNote(state, increaseContrast: increaseContrast) ?? ThemeSettingsView.contrastNote : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func listsNote(_ state: ThemeState) -> String {
        [Self.compactNote, SettingsSearch.workingRingNote].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Look

    @ViewBuilder private func look(_ state: ThemeState) -> some View {
        Section {
            if ThemeFeature.desktopLook {
                LookModePicker(desktop: state.desktopLook) { on in
                    guard on != state.desktopLook else { return }
                    Haptics.play(.selection)
                    Theme.shared.setDesktopLook(on)
                }
                .revealRow(AppearanceRows.desktopLook, revealed)
            }
            lightOrDark
            themeRow(state)
            if state.desktopLook {
                highContrastRow(state)
            }
        } header: { header(.look) } footer: {
            if let note = lookNote(state) { HQSectionFooter { Text(note) } }
        }
    }

    private func themeRow(_ state: ThemeState) -> some View {
        NavRow(title: "Theme", systemImage: "paintpalette", value: state.skin.label) {
            router.push(ThemeSettingsController(services: model.services))
        }
        .accessibilityIdentifier("settings.theme-row")
    }

    private func highContrastRow(_ state: ThemeState) -> some View {
        Toggle(isOn: Binding(get: { ThemeContrast.switchOn(state, increaseContrast: increaseContrast) }, set: { on in
            Haptics.play(.selection)
            Theme.shared.setHighContrast(on)
        })) {
            SettingsRowLabel(title: "High Contrast", systemImage: "circle.righthalf.filled")
        }
        .tint(Color.hqTintText)
        .disabled(increaseContrast)
        .accessibilityIdentifier("theme.highContrast")
        .revealRow(AppearanceRows.highContrast, revealed)
    }

    /// Light or Dark: a value alone while a one-look skin is picked, the form's pop-up on the Mac, a menu on the iPhone.
    @ViewBuilder private var lightOrDark: some View {
        if let forced = AppearanceSetting.forcedBySkin {
            // [desktoplook2] A skin with one look: the row says so instead of offering a choice that does nothing.
            LabeledContent {
                Text(forced.title).foregroundStyle(Color.hqLabel2)
            } label: {
                SettingsRowLabel(title: "Light or Dark", systemImage: "circle.lefthalf.filled")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.appearance")
            .revealRow(AppearanceRows.lightOrDark, revealed)
        } else if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 round 6: the form's bordered pop-up (`MacPopUp`), as on every Settings page.
            HStack(spacing: 12) {
                SettingsRowLabel(title: "Light or Dark", macSymbol: "circle.lefthalf.filled")
                Spacer(minLength: 16)
                MacPopUp(label: "Light or Dark", selection: $model.appearance, options: AppearanceSetting.allCases) { $0.title }
                    .accessibilityIdentifier("settings.appearance")
                    .hqMacSettingsControl()
            }
            .onChange(of: model.appearance) { _, value in
                AppearanceSetting.current = value
            }
            .revealRow(AppearanceRows.lightOrDark, revealed)
        } else {
            // UX study 2026-10-21 #60: a menu Picker drops its Label's icon, so the title is the row's label and the
            // picker only its value, with the Menu over the row (#107).
            SettingsMenuRowFace(label: SettingsRowLabel(title: "Light or Dark", systemImage: "circle.lefthalf.filled"), value: model.appearance.title)
                .overlay {
                    Menu {
                        Picker("Light or Dark", selection: $model.appearance) {
                            ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Light or Dark")
                    .accessibilityValue(model.appearance.title)
                    .accessibilityIdentifier("settings.appearance")
                }
                .onChange(of: model.appearance) { _, value in
                    Haptics.play(.selection)
                    AppearanceSetting.current = value
                }
                .revealRow(AppearanceRows.lightOrDark, revealed)
        }
    }

    // MARK: Text Size

    @ViewBuilder private func size(_ state: ThemeState) -> some View {
        Section {
            UIScaleRow(state: state, symbol: "textformat.size")
                .revealRow(AppearanceRows.uiScale, revealed)
        } header: { header(.size) } footer: { HQSectionFooter { Text(ThemeSettingsView.conciseScaleNote) } }
    }

    // MARK: Chats

    @ViewBuilder private func chats(_ state: ThemeState) -> some View {
        Section {
            chatBubblesRow(state)
            if !state.desktopLook { backgroundsRow(state) }
            thinkingBarRow
        } header: { header(.chats) }
    }

    /// In the Desktop Look the page holds that look's own Corners and Text Box.
    private func chatBubblesRow(_ state: ThemeState) -> some View {
        NavRow(title: "Chat Bubbles", systemImage: "bubble.left.and.bubble.right",
               value: state.desktopLook ? "\(state.desktopCorners) pt" : BubbleStyles.shown(state.bubbleStyle).title) {
            SettingsNavigator.openRoot("chat-bubbles", router: router)
        }
        .accessibilityIdentifier("settings.chat-bubbles-row")
    }

    /// Shown in the iOS look only: the Desktop Look keeps its plain pages.
    private func backgroundsRow(_ state: ThemeState) -> some View {
        NavRow(title: "Backgrounds", systemImage: "photo.on.rectangle", value: BackdropWords.summary) {
            SettingsNavigator.openRoot("backgrounds", router: router)
        }
        .accessibilityIdentifier("settings.backgrounds-row")
    }

    /// [thinking-drive] Thinking Bar in Appearance › Chats on both iPhone and Mac (hidden in the Mac Desktop Look,
    /// where the bar draws calmly whatever the drive).
    @ViewBuilder private var thinkingBarRow: some View {
        let drive = Binding(get: { model.thinkingDrive }, set: { (value: ThinkingDrive) in
            Haptics.play(.selection)
            model.thinkingDrive = value
            ThinkingDrive.chosen = value
        })
        if DeviceWord.isMac {
            if model.thinkingBarShown {
                HStack(spacing: 12) {
                    SettingsRowLabel(title: "Thinking Bar", systemImage: "gauge.with.dots.needle.67percent")
                    Spacer(minLength: 16)
                    MacPopUp(label: "Thinking Bar", selection: drive, options: ThinkingDrive.allCases) { $0.title }
                        .accessibilityIdentifier("settings.thinking-drive")
                        .hqMacSettingsControl()
                }
                .revealRow(AppearanceRows.thinkingBar, revealed)
            }
        } else {
            SettingsMenuRowFace(label: SettingsRowLabel(title: "Thinking Bar", systemImage: "gauge.with.dots.needle.67percent"), value: model.thinkingDrive.title)
                .overlay {
                    Menu {
                        Picker("Thinking Bar", selection: drive) {
                            ForEach(ThinkingDrive.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Thinking Bar")
                    .accessibilityValue(model.thinkingDrive.title)
                    .accessibilityIdentifier("settings.thinking-drive")
                }
                .revealRow(AppearanceRows.thinkingBar, revealed)
        }
    }

    // MARK: Bots & Sessions

    @ViewBuilder private func lists(_ state: ThemeState) -> some View {
        Section {
            // [desktop-density] Both looks: the Desktop Look's Compact is the look as it was.
            DensityRow(state: state, symbol: "rectangle.compress.vertical")
                .revealRow(AppearanceRows.density, revealed)
            // [chats-under] The line beside each bot's chats on the Bots page, in both looks (owner 2026-11-08).
            BotChatsStyleRow { router.push(BotChatsStyleSettings.make()) }
            workingRingRow(state)
        } header: { header(.lists) } footer: { HQSectionFooter { Text(listsNote(state)) } }
    }

    /// [working-ring] The ring that travels round a working bot or chat. The switch itself ticks (a system control).
    private func workingRingRow(_ state: ThemeState) -> some View {
        Toggle(isOn: Binding(get: { workingRing }, set: { on in
            WorkingRing.isOn = on
            AppLog.trace("settings", "working ring \(on ? "on" : "off")")
        })) {
            SettingsRowLabel(title: SettingsSearch.workingRingLabel, systemImage: "circle.dashed")
        }
        .tint(state.desktopLook ? Color.hqTintText : nil)
        .accessibilityIdentifier("theme.workingRing")
        .revealRow(AppearanceRows.workingRing, revealed)
    }

    // MARK: App

    /// [chat-soft-edge] No Top Edge in the Desktop Look: its tabs have their own backing and chats are always soft.
    private func topEdgeShown(_ state: ThemeState) -> Bool { TopEdgeStyle.offered && !state.desktopLook }

    private func topEdgeRow(_ state: ThemeState) -> some View {
        TopEdgeRow(state: state, symbol: "rectangle.topthird.inset.filled")
            .revealRow(AppearanceRows.topEdge, revealed)
    }

    @ViewBuilder private func app(_ state: ThemeState) -> some View {
        Section {
            tabsRow
            if topEdgeShown(state) { topEdgeRow(state) }
            appIconRow
        } header: { header(.app) } footer: {
            if topEdgeShown(state) { HQSectionFooter { Text(ThemeSettingsView.topEdgeNote(state)) } }
        }
    }

    /// [taborder] [mac] Mac polish #131: "Sidebar" on the Mac, which has no tab bar, with a sidebar's glyph.
    private var tabsRow: some View {
        NavRow(title: SettingsWords.tabsPageTitle(), systemImage: DeviceWord.isMac ? "sidebar.left" : "dock.rectangle") {
            SettingsNavigator.openRoot("tab-order", router: router)
        }
        .accessibilityIdentifier("settings.tab-order")
    }

    /// [app-icons] Only an iPhone or iPad that can't change its icon goes without the row.
    @ViewBuilder private var appIconRow: some View {
        if AppIcons.canChange {
            NavRow(title: "App Icon", systemImage: "app.badge", value: model.appIconTitle) { SettingsNavigator.openRoot("app-icon", router: router) }
                .accessibilityIdentifier("settings.app-icon")
        }
    }

    // MARK: Reset

    @ViewBuilder private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Text("Reset Appearance…")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("settings.appearance-reset")
            .confirmationDialog("Reset Appearance?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Appearance", role: .destructive) {
                    Haptics.play(.selection)
                    Theme.shared.resetAppearance()
                    model.appearance = .system
                    workingRing = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores the default theme, look, text size, chat bubbles, and backgrounds on this \(DeviceWord.name).")
            }
        } footer: {
            HQSectionFooter {
                Text("Appearance settings stay on this \(DeviceWord.name).")
            }
        }
    }

}

/// Visual two-card Look switcher (`Native` | `Hermes`) at the top of Settings › Appearance.
private struct LookModePicker: View {
    var desktop: Bool
    var pick: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            card(title: "Native", isDesktop: false, selected: !desktop)
            card(title: "Hermes", isDesktop: true, selected: desktop)
        }
        .hqRowPadding(4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.desktopLook")
    }

    private func card(title: String, isDesktop: Bool, selected: Bool) -> some View {
        let corner: CGFloat = desktop ? 4 : 12
        let miniCorner: CGFloat = isDesktop ? 4 : 9
        return Button { pick(isDesktop) } label: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    if isDesktop {
                        Capsule()
                            .fill(Color.hqLabel2.opacity(0.5))
                            .frame(width: 68, height: 6)
                        HStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.hqTint.opacity(0.18))
                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.hqTintText, lineWidth: 1))
                                .frame(width: 48, height: 11)
                        }
                    } else {
                        Capsule()
                            .fill(Color.hqBotBubble)
                            .frame(width: 62, height: 10)
                        HStack {
                            Spacer(minLength: 0)
                            Capsule()
                                .fill(Color.hqTint)
                                .frame(width: 44, height: 10)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .background(Color.hqPage, in: RoundedRectangle(cornerRadius: miniCorner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: miniCorner, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline))
                .accessibilityHidden(true)

                HStack(spacing: 4) {
                    Text(title)
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(Font.hq(.caption).weight(.bold))
                            .foregroundStyle(Color.hqTintText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: HQPalette.groupedPage), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(selected ? Color.hqTintText : Color.hqStroke, lineWidth: selected ? 2 : HQShape.hairline))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) Look")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(isDesktop ? "theme.desktopLook.desktop" : "theme.desktopLook.ios")
    }
}

// MARK: - Controls (they were the Theme page's)

/// UI Scale's presets: the app's text size, in both looks.
struct UIScaleRow: View {
    var state: ThemeState
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                AppearanceControlTitle(title: "UI Scale", symbol: symbol)
                Spacer(minLength: 0)
            }
            if !state.desktopLook {
                // Native rounded iOS segmented control in the iOS look on every device (iPhone, iPad, Mac).
                HQSegmentedPicker("UI Scale", options: ThemeState.scalePresets.map { ("\($0)%", $0) },
                                  selection: Binding(get: { state.uiScalePercent }, set: { percent in
                                      guard percent != state.uiScalePercent else { return }
                                      Haptics.play(.selection)
                                      Theme.shared.setUIScale(percent)
                                  }), ticks: false)
                    .labelsHidden()
                    .accessibilityIdentifier("theme.uiScale")
            } else {
                ScaleSegments(selected: state.uiScalePercent) { percent in
                    Haptics.play(.selection)
                    Theme.shared.setUIScale(percent)
                }
            }
        }
        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
    }
}

/// [density] Standard or Compact. [desktop-density] Each look has its own; the Desktop Look's Compact is its rows as they were.
struct DensityRow: View {
    var state: ThemeState
    var symbol: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// [desktop-density] Owner 2026-11-22: the strip hugged its words (10 pt beside each in the Desktop Look). Two equal
    /// halves of a set width, so both words have 20 pt or more beside them, in iOS's own segments too.
    private var stripWidth: CGFloat { HQFont.scaled(state.desktopLook ? 204 : 180) }
    /// What the name and the strip need side by side: the symbol's column, the name whole on one line, the strip.
    /// A row's label reports no width of its own to `ViewThatFits`, so the name is measured here.
    private var besideWidth: CGFloat {
        let name = ("Density" as NSString).size(withAttributes: [.font: HQFont.preferred(.body)]).width.rounded(.up)
        return (symbol == nil ? 0 : HQFont.scaled(52) * max(1, HQFont.dynamicRatio(nil))) + name + 12 + stripWidth
    }

    var body: some View {
        let _ = typeSize   // measured again at a new text size
        // Where the name no longer fits whole beside the strip (a large UI Scale or text size: it broke mid-word), the
        // strip goes under it at the row's width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                AppearanceControlTitle(title: "Density", symbol: symbol)
                Spacer(minLength: 8)
                picker.frame(minWidth: stripWidth).fixedSize()
            }
            .frame(minWidth: besideWidth)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    AppearanceControlTitle(title: "Density", symbol: symbol)
                    Spacer(minLength: 0)
                }
                picker
            }
            .hqRowPadding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.density")
    }

    private var picker: some View {
        HQSegmentedPicker("Density", options: [("Standard", ListDensity.standard), ("Compact", ListDensity.compact)],
                          selection: Binding(get: { state.appliedDensity }, set: { next in
                              guard next != state.appliedDensity else { return }
                              Haptics.play(.selection)
                              Theme.shared.setDensity(next)
                              AppLog.trace("settings", "density \(next.rawValue)")
                          }), ticks: false, wholeLabels: true)
        .labelsHidden()
    }
}

/// [top-edge] Soft or Hard: how rows meet the top bar where they scroll under it.
struct TopEdgeRow: View {
    var state: ThemeState
    var symbol: String?

    var body: some View {
        HStack(spacing: 12) {
            AppearanceControlTitle(title: "Top Edge", symbol: symbol)
            Spacer(minLength: 8)
            HQSegmentedPicker("Top Edge", options: [("Soft", TopEdge.soft), ("Hard", TopEdge.hard)],
                              selection: Binding(get: { state.topEdge }, set: { next in
                                  guard next != state.topEdge else { return }
                                  Haptics.play(.selection)
                                  Theme.shared.setTopEdge(next)
                                  AppLog.trace("settings", "top edge \(next.rawValue)")
                              }), ticks: false)
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.topEdge")
    }
}

/// A control row's title: with the row's symbol in a card whose rows have one, else the words alone.
private struct AppearanceControlTitle: View {
    var title: String
    var symbol: String?

    var body: some View {
        if let symbol {
            SettingsRowLabel(title: title, systemImage: symbol)
        } else {
            Text(title).foregroundStyle(Color.hqLabel).fixedSize()
        }
    }
}
