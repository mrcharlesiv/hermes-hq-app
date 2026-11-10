// [mac] Stress test 2026-10-28 #51, #8, #94, #102, #93: the Mac's Settings form. Settings and config pages were iPhone
// Settings screens stretched across the pane: a label at one edge and its value ~1000 pt away, iPhone switches, a card
// per setting with its help between, and a page pushed to change one number or pick one value. On the Mac every
// settings list (`settingsList()`, the Settings root) is a form of readable width, centred in the pane, with one row
// height, equal gaps between cards and small switches; config fields are drawn in place as a label column and a control
// at one x (a pop-up, a number field with its unit, a text field, a switch), the help under the label across the row. Off the Mac
// none of this exists: every helper here is a no-op or draws what the page drew before.

import SwiftUI
import UIKit

/// [mac] The form's measures. App points: the Mac draws them at 77 %, and they grow with the look's base and UI Scale
/// as the text does (`HQFont.scaled`).
@MainActor enum MacForm {
    /// The readable width a settings page is capped to: about 640 pt on the screen at 100 % in both looks, growing with
    /// UI Scale. [mac] Stress test 2026-10-28 #8: it was `HQFont.scaled(720)`, which also takes the look's own Mac base
    /// (× 1.3 in the Desktop Look against × 1.15 in the iOS look), so the Desktop Look's cap was 936 pt: about the whole
    /// ~990 pt pane, and its pages never looked capped. Now the iOS look's base in both looks, so the column is one width
    /// on the screen whichever look is on.
    static var readableWidth: CGFloat {
        let state = ThemeTable.current.state
        return (720 * CGFloat(state.uiScalePercent) / 100 * CGFloat(ThemeState.macBase(desktopLook: false))).rounded()
    }
    /// The side inset that centres the readable column in a pane `width` wide (the cards' own 20 pt at the least).
    static func side(in width: CGFloat) -> CGFloat { max(MacInset.side, ((width - readableWidth) / 2).rounded()) }
    /// [mac] #8 (review): an inset-grouped UITableView page (More › Files and Changes) at the same readable width: its
    /// sections are inset by the table's layout margins. Call from `viewDidLayoutSubviews`; nothing off the Mac.
    static func capReadableWidth(_ table: UITableView) {
        guard DeviceWord.isMac, table.style == .insetGrouped, table.bounds.width > 0 else { return }
        let side = side(in: table.bounds.width)
        let margins = table.directionalLayoutMargins
        guard margins.leading != side || margins.trailing != side else { return }
        table.preservesSuperviewLayoutMargins = false
        table.insetsLayoutMarginsFromSafeArea = false
        table.cellLayoutMarginsFollowReadableWidth = false
        table.directionalLayoutMargins = NSDirectionalEdgeInsets(top: margins.top, leading: side, bottom: margins.bottom, trailing: side)
    }
    /// The label column, at most this wide (and never more than 45 % of a narrow pane). [mac] #7 (review): wider, so
    /// "Automatic Repository Discovery" and the like stay on one line.
    /// [mac] Stress test 2026-10-28 round 7: one column in window points in both looks. `HQFont.scaled(260)` took the
    /// look's own Mac base (× 1.3 Desktop Look, × 1.15 iOS look), so the control column stood at x 947 in one look and
    /// 915 in the other. Now the Desktop Look's base in both (its larger text needs the room), as `switchHeight` does.
    static var labelWidth: CGFloat {
        let state = ThemeTable.current.state
        return (260 * CGFloat(state.uiScalePercent) / 100 * CGFloat(ThemeState.macBase(desktopLook: true))).rounded()
    }
    static let columnGap: CGFloat = 16
    /// [mac] Stress test 2026-10-28 round 7: the one gap between a radio and its title on every page (Voice Model's rows
    /// had 16 against the others' 8, so their titles started 7 px further right).
    static let radioGap: CGFloat = 8
    /// One height for every row, with or without a symbol or a switch (#93).
    static var rowHeight: CGFloat { (HQFont.preferred(.body).lineHeight + 22).rounded() }
    /// [mac] Stress test 2026-10-28 round 8: the room above and under a row's content once the form takes the list's own
    /// row insets away (`hqMacFormRowHeight`). A one-line row (a control as tall as `controlHeight` at most) stays inside
    /// `rowHeight`; a row with help under it grows by its lines and keeps about the room it had.
    static let rowPad: CGFloat = 6
    static let multilineRowPad: CGFloat = 10
    /// [mac] Stress test 2026-10-28 round 9: the one height of every one-line row on the Settings root and its pages,
    /// whatever its control (a chevron, a value, a switch, a pop-up, a field, an Add row). Round 8 took the list's row
    /// insets off some kinds (chevron and value rows went to 44 pt) and left them on the others (switch and pop-up rows
    /// stayed at 61). Now no Settings row loses its insets: each keeps the list's own room above and under it, so a
    /// two-line row is its lines plus that one room whatever its control, and a one-line row is at least this tall:
    /// a pop-up or field (`controlHeight`, the tallest one-line control) with even room above and under it (about
    /// 61 pt on the screen at 100 %, a pop-up 33 of it with 14 above and under, the list's own room; the 61 pt the
    /// switch rows already were).
    /// [mac-ui-issues] Owner 2026-11-09 (Settings "way too iOS-like"): a Mac settings row, not an iPhone's. The list's
    /// own room above and under a row (11 pt each, the iPhone's) is `settingsRowInset` on every Settings row instead, set
    /// once on the list, so the rows are still one height whatever their control: about 36 pt on the screen at 100 %.
    static var settingsRowHeight: CGFloat { controlHeight + 2 * settingsRowInset }
    static let settingsRowInset: CGFloat = 8
    /// One gap between cards, whether or not the card above has a footer (#102).
    static let sectionGap: CGFloat = 22
    /// [mac] Stress test 2026-10-28 round 8: a size in window points that is the same in both looks: `value` at the
    /// Desktop Look's Mac base and UI Scale, as `labelWidth` and `switchHeight` are. `HQFont.scaled` takes the look's own
    /// base (× 1.3 Desktop Look, × 1.15 iOS look), so a box sized with it was about 12 % smaller in the iOS look.
    static func fixed(_ value: CGFloat) -> CGFloat {
        let state = ThemeTable.current.state
        return (value * CGFloat(state.uiScalePercent) / 100 * CGFloat(ThemeState.macBase(desktopLook: true))).rounded()
    }
    /// A number field's width (about eight digits). [mac] Round 8: one width in both looks (`fixed`); it was
    /// `HQFont.scaled(96)`, 125 pt in the Desktop Look against 110 in the iOS look.
    static var numberWidth: CGFloat { fixed(96) }
    /// [mac] Stress test 2026-10-28 round 8: one height for a field and a pop-up button (fields were 34 pt beside 32 pt
    /// pop-ups): a line of the form's text and 4 pt above and under it, as the pop-up's face has.
    static var controlHeight: CGFloat { HQFont.preferred(.body).lineHeight.rounded(.up) + 8 }
    /// [mac] Stress test 2026-10-28 round 9: how far a control (`controlHeight`) stands above and under a line of the
    /// form's text centred on it.
    static var controlOverhang: CGFloat { ((controlHeight - HQFont.preferred(.body).lineHeight) / 2).rounded(.down) }
    /// A small switch: about 38 × 22 on the screen (the Mac's own) at 100 %, growing with UI Scale. [mac] Stress test
    /// 2026-10-28 #51 (round 6): one size in both looks. It took the look's own Mac base (`HQFont.scaled`), so the
    /// iOS look's was 44 × 25 px against the Desktop Look's 49 × 28; now the Desktop Look's base in both, as
    /// `readableWidth` takes one base.
    static var switchHeight: CGFloat {
        let state = ThemeTable.current.state
        return (22 * CGFloat(state.uiScalePercent) / 100 * CGFloat(ThemeState.macBase(desktopLook: true)) * 2).rounded() / 2
    }
}

private struct MacFormLabelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct MacSettingsFormKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// [mac] Stress test 2026-10-28 round 9: this row is on a Settings page (`hqMacForm(settings: true)`).
    var macSettingsForm: Bool {
        get { self[MacSettingsFormKey.self] }
        set { self[MacSettingsFormKey.self] = newValue }
    }

    /// [mac] The label column of the form this row is in (0 outside one).
    var macFormLabelWidth: CGFloat {
        get { self[MacFormLabelWidthKey.self] }
        set { self[MacFormLabelWidthKey.self] = newValue }
    }
}

extension View {
    /// [mac] #8, #93, #102, #51: a settings list as a Mac form (readable width centred in the pane, one row height,
    /// equal gaps, small switches). Put it inside `hqGroupedPage()` so its section gap wins. Elsewhere nothing.
    /// `settings`: [mac] Stress test 2026-10-28 round 9: a page of Settings (the root and the pages it opens), whose
    /// rows keep the list's own insets and are at least `MacForm.settingsRowHeight` tall (`hqMacFormRowHeight` leaves
    /// them be). More's pages keep the form's earlier rows. A `settingsList()` page says so with `hqMacSettingsRows()`.
    @ViewBuilder func hqMacForm(settings: Bool = false) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacFormPage(settings: settings))
        #else
        self
        #endif
    }
}

extension View {
    /// [mac-ui-issues] Every row of a Settings list takes the Mac's room above and under it (`MacForm.settingsRowInset`).
    /// On the list's content (a Group round its sections): set on the List itself it reaches no row. Nothing on the
    /// iPhone and iPad.
    @ViewBuilder func hqMacSettingsRowInsets() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacSettingsRowInsets())
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)

/// Only on a Settings page (`macSettingsForm`, set round the list): More's forms keep their own rows.
private struct MacSettingsRowInsets: ViewModifier {
    @Environment(\.macSettingsForm) private var settings
    func body(content: Content) -> some View {
        if settings { content.listRowInsets(.vertical, MacForm.settingsRowInset) } else { content }
    }
}

private struct MacFormPage: ViewModifier {
    var settings = false
    /// [mac] Round 9: set round the page by `hqMacSettingsRows()` (a `settingsList()` page of Settings).
    @Environment(\.macSettingsForm) private var settingsAround
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let _ = Theme.touch()
        let readable = MacForm.readableWidth
        // The cards' own inset (20) stays the least; a wider pane centres the readable column.
        let side = MacForm.side(in: width)
        let column = width > 0 ? min(MacForm.labelWidth, (min(width, readable) - 80) * 0.45) : MacForm.labelWidth
        let settings = self.settings || settingsAround
        content
            // [mac] Stress test 2026-10-28 round 9: a Settings page's one row height (`MacForm.settingsRowHeight`).
            .environment(\.defaultMinListRowHeight, settings ? MacForm.settingsRowHeight : MacForm.rowHeight)
            .environment(\.macSettingsForm, settings)
            .contentMargins(.horizontal, side, for: .scrollContent)
            // [mac] Stress test 2026-10-28 #53: one gap under the bar on every form page (the first card started at
            // about 100 on some pages and 117 on others).
            .contentMargins(.top, MacInset.top, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .environment(\.macFormLabelWidth, max(120, column))
            .listSectionSpacing(MacForm.sectionGap)
            .toggleStyle(MacSwitchStyle())
    }
}
#endif

// MARK: - A small switch

/// [mac] #51: the Mac's switch size (iOS's was about 62 × 28 on the screen) and an off state that reads as off in the
/// Desktop Look dark (iOS's off switch there was a near-white pill, brighter than an on one). The title leads, the
/// switch trails, as a Toggle's row does.
struct MacSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // [mac] Stress test 2026-10-28 round 8: the switch sits on the title's line, as a form row's switch does (Detailed
        // Logging's was centred on its title and note, between the two lines). On a one-line row it is centred as before.
        let line = HQFont.preferred(.body).lineHeight
        HStack(alignment: .top, spacing: 12) {
            MacSwitchLabel { configuration.label }
            // [mac] Stress test 2026-10-28 round 9: centred on the title's line and no taller than it, so a switch row
            // with a note under its title is its lines and the list's room, as a row that opens a page with the same
            // lines is (Detailed Logging 78 pt against 75 for Keys' ByteRover). The switch stands 2 pt over the line.
            MacSwitch(isOn: configuration.$isOn)
                .frame(height: line)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// [mac] Stress test 2026-10-28 #51 (round 6): a switched-off row reads as one. Notifications' kinds are switched off
/// while notifications are off in System Settings: their switches drew the dimmed (paler) on track, as designed, but
/// beside full-strength titles they read as broken on switches. The title and its subtitle now dim with the switch.
private struct MacSwitchLabel<Label: View>: View {
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labels

    var body: some View {
        // [mac] Stress test 2026-10-28 round 8: in the iOS look half strength left a subtitle at 2.3:1 on the white card
        // (Notifications); 70 % keeps it at about 3.4:1, still plainly dimmer than an enabled row. The Desktop Look's
        // half strength already reads at 3:1 or better and is kept.
        let _ = Theme.touch()
        // [mac] Stress test 2026-10-31: `.labelsHidden()` is honoured, as the system's switch does. A switch beside its
        // own row's words (Webhooks) drew its label a second time ("github-push" by the switch).
        if labels != .hidden {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(enabled ? 1 : Theme.isDesktop ? 0.5 : 0.7)
        }
    }
}

/// [mac] The switch itself: a track and a knob, the look's accent when on and a soft grey when off.
struct MacSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let _ = Theme.touch()
        let height = MacForm.switchHeight
        let on = Theme.isDesktop ? Color.hqTintText : Color.hqTint
        // [mac] Stress test 2026-10-28 #51 (review): dimmed, the whole switch at 45 % was a grey knob on a navy track in
        // the Desktop Look dark, neither on nor off. Now a dimmed switch keeps its state's shape: on is a paler accent
        // track with the white knob at the trailing end, off an outlined empty track with a grey knob at the leading end.
        // [mac] Stress test 2026-10-28 #51 (round 6): in the iOS look an off switch was a pale grey track on the white
        // card and almost vanished. Its off track is now a visible grey with a hairline edge, as a Mac's switch; the
        // Desktop Look's dark off track stays as it was (darker than on, which is the point there).
        let desktop = Theme.isDesktop
        let offFill = desktop ? Color.hqLabel3.opacity(enabled ? 0.45 : 0.18) : Color.hqLabel3.opacity(enabled ? 0.75 : 0.35)
        let track: Color = isOn ? on.opacity(enabled ? 1 : 0.4) : offFill
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(track)
                .overlay {
                    if !isOn, !enabled || !desktop {
                        Capsule().strokeBorder(Color.hqLabel3.opacity(enabled ? 0.5 : 0.6), lineWidth: 1)
                    }
                }
            Circle()
                .fill(enabled || isOn ? Color.white : Color.hqLabel3)
                .shadow(color: .black.opacity(enabled ? 0.25 : 0), radius: 0.5, y: 0.5)
                .padding(enabled || isOn ? 2 : 4)
        }
        .frame(width: (height * 1.72).rounded(), height: height)
        .contentShape(Capsule())
        .onTapGesture {
            guard enabled else { return }
            HQMotion.withAnimation(.snappy(duration: 0.18)) { isOn.toggle() }
        }
    }
}

// MARK: - A form row

/// [mac] #51, #94: a label in the form's column and its control at one x, with short help under the label across the row.
struct MacFormRow<Control: View>: View {
    var label: String
    var help: String? = nil
    /// [mac] #7 (review): a switch trails the row and its label takes the rest of it (and its help the whole width), as
    /// a Mac form's switches do: in the label column a long label ("Automatic Repository Discovery") wrapped onto two
    /// lines with the switch floating between them.
    var trailing = false
    @ViewBuilder var control: Control
    @Environment(\.macFormLabelWidth) private var column
    @Environment(\.macSettingsForm) private var settingsForm
    /// [mac] Stress test 2026-10-28 round 7: a disabled row reads as disabled at a readable contrast: its label in the
    /// secondary label colour (Mixture of Agents faded whole rows to 45 %, about 1.5:1).
    @Environment(\.isEnabled) private var enabled
    private var labelColor: Color { enabled ? Color.hqLabel : Color.hqLabel2 }

    var body: some View {
        let labelWidth = column > 0 ? column : MacForm.labelWidth
        if trailing {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: MacForm.columnGap) {
                    Text(label)
                        .foregroundStyle(labelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    control
                        // [mac] Stress test 2026-10-28 round 10: the switch takes the title's line, as `MacSwitchStyle`'s
                        // does, so a config page's switch row with help under it is its lines and the list's room (it was
                        // 81 pt with its title 3 pt low against 76 for Settings' own two-line switch rows).
                        .frame(height: HQFont.preferred(.body).lineHeight)
                }
                if let help, !help.isEmpty {
                    Text(help)
                        .font(MacType.footnoteFont)
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .hqMacFormRowHeight(multiline: hasHelp)
        } else {
            columns(labelWidth)
                .hqMacFormRowHeight(multiline: hasHelp)
        }
    }

    private var hasHelp: Bool { !(help ?? "").isEmpty }

    private func columns(_ labelWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: MacForm.columnGap) {
                Text(label)
                    .foregroundStyle(labelColor)
                    .frame(width: labelWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // [mac] Stress test 2026-10-28 round 9: with help under it, the control (a pop-up, a field, an Edit…
                    // button, each `MacForm.controlHeight`) takes no more height than the label's line, so the row is
                    // its lines and the list's room, as a switch row or a row that opens a page with the same lines is
                    // (Keys' Telegram pop-up row was about 75 pt against 67 for the switch rows beside it).
                    // [mac] Stress test 2026-10-28 round 10: on a Settings page a one-line row's control does too, so a
                    // pop-up row is the page's one row height (it was 61-62 pt against 59 for switch and chevron rows).
                    .padding(.vertical, hasHelp || settingsForm ? -MacForm.controlOverhang : 0)
            }
            if let help, !help.isEmpty {
                // [mac] Stress test 2026-10-28 round 6: help under the label, across the row, as a switch row's is (under
                // the control column it wrapped early, "…scoped to the / current project.", and one card had help two ways).
                Text(help)
                    .font(MacType.footnoteFont)
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// [mac] Stress test 2026-10-28 round 9: a `settingsList()` page of Settings: its rows are Settings' rows
    /// (`hqMacForm(settings: true)`). Put it after `settingsList()`. Elsewhere nothing.
    @ViewBuilder func hqMacSettingsRows() -> some View {
        if DeviceWord.isMac { environment(\.macSettingsForm, true) } else { self }
    }

    /// [mac] Stress test 2026-10-28 round 8: one height for every one-line row of a Mac form whatever its control. A
    /// pop-up row was 68 pt, a switch row 58, a row with a symbol 58 and a plain row 53: each was its content plus the
    /// list's own row insets, so the tallest control set the row. The insets above and under are taken away and the
    /// row is at least `MacForm.rowHeight`, with `MacForm.rowPad` round its content: every one-line control fits inside
    /// it, so each such row is `rowHeight`. `multiline`: a row with help or a note under its title, which grows by its
    /// lines with a little more room. Elsewhere nothing.
    /// [mac] Stress test 2026-10-28 round 9: on a Settings page (`hqMacForm(settings: true)`) nothing: every row there
    /// keeps the list's insets and the page's one row height (`MacForm.settingsRowHeight`), so a row this is on is
    /// the height of its neighbours that it isn't on (Tool Calls was 44 against the switches' 61 under it).
    @ViewBuilder func hqMacFormRowHeight(multiline: Bool = false) -> some View {
        if DeviceWord.isMac {
            modifier(MacFormRowHeight(multiline: multiline))
        } else {
            self
        }
    }

    /// [mac] Stress test 2026-10-28 round 10: a control (a pop-up, a chooser, a push button) standing alone at a row's
    /// trailing or leading edge on a Settings page takes no more height than a line of the form's text, as a switch or a
    /// value does, so its row is the page's one height (`MacForm.settingsRowHeight`): the list's room round a 32 pt
    /// pop-up made Light or Dark and Add Gateway… 61-62 pt beside 59 pt rows. The control draws at its own height.
    /// Elsewhere (More's forms, the iPhone) nothing.
    @ViewBuilder func hqMacSettingsControl() -> some View {
        if DeviceWord.isMac { modifier(MacSettingsControl()) } else { self }
    }

    /// [mac] Stress test 2026-10-28 round 9: the iPhone's own room above and under a row's content (`.padding(.vertical,
    /// value)`); none on the Mac, where every Settings row has the list's one room and a row with more lines is taller
    /// only by its lines (Keys' rows that open a page were 83 pt against 67 for switch rows with the same two lines).
    @ViewBuilder func hqRowPadding(_ value: CGFloat) -> some View {
        padding(.vertical, DeviceWord.isMac ? 0 : value)
    }
}

/// [mac] Stress test 2026-10-28 round 10: `hqMacSettingsControl` on the Mac.
private struct MacSettingsControl: ViewModifier {
    @Environment(\.macSettingsForm) private var settings

    func body(content: Content) -> some View {
        content.padding(.vertical, settings ? -MacForm.controlOverhang : 0)
    }
}

/// [mac] `hqMacFormRowHeight` on the Mac: More's form rows (the list's insets off, `MacForm.rowPad` round the content,
/// `MacForm.rowHeight` at the least); on a Settings page the row as it is (round 9).
private struct MacFormRowHeight: ViewModifier {
    var multiline: Bool
    @Environment(\.macSettingsForm) private var settings

    func body(content: Content) -> some View {
        if settings {
            content
        } else {
            content.padding(.vertical, multiline ? MacForm.multilineRowPad : MacForm.rowPad)
                .frame(maxWidth: .infinity, minHeight: MacForm.rowHeight, alignment: .leading)
                .listRowInsets(.vertical, 0)
        }
    }
}

// MARK: - A config field in place

/// [mac] #51, #94, #95, #101: one gateway config field drawn in place: a switch, a pop-up for a closed list, a number
/// field with its unit, a text field, or (a list, JSON, a long text, a long or open list of names) its summary and an
/// Edit… button that opens the field's own editor. Saves go through the store as the editors' do.
struct MacConfigFieldRow: View {
    let field: ConfigFieldModel
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// False where the section's footer already says what the field does (Main Model's Reasoning Effort).
    var showsHelp = true

    /// The most choices a pop-up lists; longer lists (time zones) keep their searchable page.
    static let popUpLimit = 40

    var body: some View {
        let held = ConfigCatalog.heldNow(config: store.config).contains(field.key)
        MacFormRow(label: ConfigUnits.label(field.label, key: field.key), help: help(held: held), trailing: field.control == .toggle) {
            control
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("config-field.\(field.key)")
        .revealRow(ConfigFieldReveal.rowID(field.key), ConfigFieldReveal.shared.marked)   // a search result's row (Mac polish #39)
        // Mac polish #98: dimmed and held while the switch it depends on is off (`ConfigCatalog.parentSwitch`).
        .disabled(held)
        .contextMenu {
            if field.canReset {
                Button("Reset to Default", systemImage: "arrow.uturn.backward") {
                    Haptics.play(.selection)
                    store.reset(field.key)
                }
            }
        }
    }

    /// The field's help, and while it is held by a switch on another page, where to turn that on (Mac polish #98).
    private func help(held: Bool) -> String? {
        let parts = [showsHelp ? field.description.map(ConfigUnits.sentence) : nil, held ? ConfigCatalog.heldHelp[field.key] : nil]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder private var control: some View {
        switch field.control {
        case .toggle:
            MacSwitch(isOn: Binding(get: { field.value?.bool ?? false }, set: { store.set(field.key, .bool($0)) }))
                .accessibilityElement()
                .accessibilityLabel(field.label)
                .accessibilityValue(field.value?.bool == true ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityAction { store.set(field.key, .bool(!(field.value?.bool ?? false))) }
        case .choice(let options, let free, _) where !free && options.count <= Self.popUpLimit:
            MacPopUp(label: field.label, selection: Binding(
                // Reasoning effort's blank or "false" is shown as the page's editor shows it ("Medium", "None").
                get: { field.key == "agent.reasoning_effort" ? ConfigCopy.reasoningEffort(field.value) : ConfigText.text(field.value) },
                set: { option in
                    Haptics.play(.selection)
                    store.set(field.key, ConfigRenderer.choiceValue(key: field.key, option, current: field.value))
                }), options: options) { ConfigRenderer.optionLabel(key: field.key, $0) }
        case .number:
            MacNumberField(key: field.key, value: field.value, label: field.label) { store.set(field.key, $0) }
        case .text:
            // [mac] Stress test 2026-10-28 round 6: the placeholder says what blank means ("Main Model").
            MacTextField(value: ConfigText.text(field.value), label: field.label, placeholder: ConfigUnits.blank(key: field.key)) {
                store.set(field.key, .string($0))
            }
        default:
            HStack(spacing: 10) {
                // Mac polish #91: the summary takes the column's room and the button the row's end, so the Edit… and
                // Choose… buttons down a card stand in one column ("None Edit…" and "2 Items Edit…" started apart).
                Text(ConfigUnits.summary(field))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Self.editTitle(field.control)) { ConfigScreens.openField(field.key, store: store, router: router) }
                    .buttonStyle(MacPushButtonStyle())   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac's push button
                    .accessibilityIdentifier("config-field.\(field.key).edit")
            }
        }
    }

    static func editTitle(_ control: ConfigControl) -> String {
        if case .choice = control { return "Choose…" }
        return "Edit…"
    }
}

/// [mac] #95: a number typed in place, grouped ("100,000") and followed by its unit ("tokens", "%"). What it writes is
/// the value the page's editor wrote (a percent's 50 writes 0.5); an untouched field writes nothing, and a field that
/// isn't a number (or is out of range) says so under it and writes nothing.
struct MacNumberField: View {
    let key: String
    let value: JSONValue?
    let label: String
    let commit: (JSONValue) -> Void
    @State private var text = ""
    @State private var loaded = ""
    @State private var problem: String?
    @FocusState private var focused: Bool
    /// Mac polish #98: held (its switch off), the field fades as the push buttons do.
    @Environment(\.isEnabled) private var enabled

    private var automatic: Bool { ConfigCopy.zeroMeansAutomatic.contains(key) && value?.double == 0 }

    private func shown(_ value: JSONValue?) -> String {
        if ConfigCopy.zeroMeansAutomatic.contains(key), value?.double == 0 { return "" }
        return ConfigUnits.fieldText(key: key, value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField(automatic ? "Automatic" : ConfigUnits.none, text: $text,
                          prompt: MacField.prompt(automatic ? "Automatic" : ConfigUnits.none))
                    // [mac] Stress test 2026-10-28 round 8: leading, as the pop-ups in the same column are (a macOS
                    // form's fields are leading-aligned); "Automatic" stood at the field's trailing end.
                    .multilineTextAlignment(.leading)
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .hqMacFieldBox()
                    .frame(width: MacForm.numberWidth)
                    .opacity(enabled ? 1 : 0.45)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel(label)
                if let unit = ConfigUnits.unitWord(key: key, value: ConfigUnits.value(key: key, text: text)?.double ?? value?.double) {
                    Text(unit).foregroundStyle(Color.hqLabel2)
                }
            }
            if let problem {
                Text(problem).font(MacType.footnoteFont).foregroundStyle(Color.hqRed)
            }
        }
        .onAppear { load() }
        .onChange(of: value) { _, _ in if !focused { load() } }
        .onChange(of: focused) { _, now in if !now { save() } }
        .onDisappear(perform: save)
    }

    private func load() {
        text = shown(value)
        loaded = text
        problem = nil
    }

    private func save() {
        guard text != loaded else { problem = nil; return }
        guard let next = ConfigUnits.value(key: key, text: text) else { problem = "Type a number."; return }
        if case .number(let typed) = next, let refusal = VoiceSettingsCatalog.numberProblem(key: key, value: typed) {
            problem = refusal
            return
        }
        problem = nil
        loaded = text
        guard !ConfigRenderer.same(next, value) else { return }
        commit(next)
    }
}

/// [mac] A one-line text value typed in place (a folder, a name). Written when Return is pressed or the field is left,
/// only when it changed.
struct MacTextField: View {
    let value: String
    let label: String
    var placeholder: String? = nil
    var keyboard: UIKeyboardType = .default
    let commit: (String) -> Void
    @State private var text = ""
    @State private var loaded = ""
    @FocusState private var focused: Bool
    /// Mac polish #98: held (its switch off), the field fades as the push buttons do.
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        TextField(ConfigUnits.none, text: $text, prompt: MacField.prompt(placeholder ?? ConfigUnits.none))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .hqMacFieldBox()
            .opacity(enabled ? 1 : 0.45)
            .focused($focused)
            .onSubmit(save)
            .accessibilityLabel(label)
            .onAppear { text = value; loaded = value }
            .onChange(of: value) { _, now in if !focused { text = now; loaded = now } }
            .onChange(of: focused) { _, now in if !now { save() } }
            .onDisappear(perform: save)
    }

    private func save() {
        guard text != loaded else { return }
        loaded = text
        commit(text)
    }
}

// MARK: - The Mac's push button

/// [mac] Stress test 2026-10-28 #55 (round 6): the Mac's one push button. Worded buttons came in four looks (iOS tinted
/// capsules with link-blue words, bordered rectangles, a solid accent rectangle, and a white-on-grey capsule at 1.6:1 that
/// read as switched off). On the Mac every one is this: a rounded rectangle in the control fill with a hairline edge
/// and label-coloured words; `prominent` (the page's one primary action) is accent-filled with its on-tint words;
/// `destructive` keeps the plain face with red words. One shape in both looks: only the palette differs.
enum MacPushKind { case plain, prominent, destructive }

@MainActor enum MacPush {
    /// About 6 pt on the screen (the Mac draws the app at 77 %).
    static let radius: CGFloat = 7.5
    static let insets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)

    /// The control fill: the card colour in the iOS look's light mode (white, as a Mac's push button), the look's
    /// third fill otherwise (a lighter grey than the page in dark, the Desktop Look's raised box).
    static let fill: UIColor = {
        let card = ThemedColor.make(\.groupedCard), fill3 = ThemedColor.make(\.fill3)
        return UIColor { @Sendable traits in
            let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
            return (!desktop && traits.userInterfaceStyle != .dark ? card : fill3).resolvedColor(with: traits)
        }
    }()
    /// The hairline edge, as the form's fields draw theirs (`MacField.stroke`).
    static let stroke: UIColor = {
        let label3 = ThemedColor.make(\.label3)
        return UIColor { @Sendable traits in
            let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
            return label3.resolvedColor(with: traits).withAlphaComponent(desktop ? 0.55 : 0.4)
        }
    }()
    static var fillColor: Color { Color(uiColor: fill) }
    static var strokeColor: Color { Color(uiColor: stroke) }

    /// UIKit's face of the same button (empty states, viewers, Try Again cards).
    static func configuration(_ kind: MacPushKind = .plain) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .fixed
        config.background.cornerRadius = radius
        config.contentInsets = insets
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = HQFont.preferred(.body)
            return copy
        }
        switch kind {
        case .prominent:
            config.background.backgroundColor = HQPalette.tint
            config.baseForegroundColor = HQPalette.onTint
        case .plain, .destructive:
            config.background.backgroundColor = fill
            config.background.strokeColor = stroke
            config.background.strokeWidth = 1
            config.baseForegroundColor = kind == .destructive ? HQPalette.red : HQPalette.label
        }
        return config
    }
}

/// [mac] #55 (round 6): the push button in SwiftUI. A `.destructive` role draws red words whatever the kind.
struct MacPushButtonStyle: ButtonStyle {
    var kind: MacPushKind = .plain
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let _ = Theme.touch()
        let shape = RoundedRectangle(cornerRadius: MacPush.radius, style: .continuous)
        let destructive = kind == .destructive || configuration.role == .destructive
        let prominent = kind == .prominent && !destructive
        configuration.label
            .font(Font.hq(.body))
            .foregroundStyle(prominent ? Color.hqOnTint : destructive ? Color.hqRed : Color.hqLabel)
            .multilineTextAlignment(.center)
            .padding(.horizontal, MacPush.insets.leading)
            .padding(.vertical, MacPush.insets.top)
            .background(shape.fill(prominent ? Color.hqTint : MacPush.fillColor))
            .overlay { if !prominent { shape.strokeBorder(MacPush.strokeColor, lineWidth: 1) } }
            .overlay { if configuration.isPressed { shape.fill(Color.hqLabel.opacity(0.1)) } }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension View {
    /// [mac] #55 (round 6): the Mac's push button; elsewhere `.buttonStyle(.bordered)`, as the call site drew before.
    @ViewBuilder func hqMacBordered(_ kind: MacPushKind = .plain) -> some View {
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle(kind: kind)) } else { self.buttonStyle(.bordered) }
    }

    /// [mac] #55 (round 6): the Mac's push button; elsewhere the button exactly as it was.
    @ViewBuilder func hqMacPushOnly(_ kind: MacPushKind = .plain) -> some View {
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle(kind: kind)) } else { self }
    }
}

// MARK: - A list editor's + and −

/// [mac] Stress test 2026-10-28 round 7: the + and − under a Mac list (Fallback Models), as macOS list editors draw them:
/// two small square cells in one bordered box with a hairline between, in the push button's fill and edge. A disabled
/// cell draws its symbol in the third label colour.
struct MacAddRemoveButtons: View {
    var addLabel: String
    var removeLabel: String
    var addHelp: String
    var removeHelp: String
    var canRemove: Bool
    var add: () -> Void
    var remove: () -> Void
    var addIdentifier: String
    var removeIdentifier: String

    var body: some View {
        let _ = Theme.touch()
        // [mac] Stress test 2026-10-28 round 8: one size in both looks (`MacForm.fixed`). `HQFont.scaled(22)` took the
        // look's own Mac base, so the pair was 58 × 28 in the Desktop Look and 52 × 26 in the iOS look.
        let side = MacForm.fixed(22)
        let shape = RoundedRectangle(cornerRadius: MacField.radius, style: .continuous)
        HStack(spacing: 0) {
            cell("plus", enabled: true, side: side, action: add)
                .help(addHelp)
                .accessibilityLabel(addLabel)
                .accessibilityIdentifier(addIdentifier)
            Rectangle().fill(MacPush.strokeColor).frame(width: 1, height: side)
            cell("minus", enabled: canRemove, side: side, action: remove)
                .disabled(!canRemove)
                .help(removeHelp)
                .accessibilityLabel(removeLabel)
                .accessibilityIdentifier(removeIdentifier)
        }
        .background(shape.fill(MacPush.fillColor))
        .overlay(shape.strokeBorder(MacPush.strokeColor, lineWidth: 1))
        .clipShape(shape)
        .fixedSize()
    }

    private func cell(_ symbol: String, enabled: Bool, side: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Font.hq(.footnote).weight(.medium))
                .foregroundStyle(enabled ? Color.hqLabel : Color.hqLabel3)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(MacAddRemoveCellStyle())
    }
}

/// [mac] Stress test 2026-10-28 round 8: an "Add …" row under a list's rows (Add to Vault…, Add Model…), one style on
/// every page: the + and the words in the accent, as a macOS list's add row; dimmed (`MacField.dimmed`) with the rows
/// around it while its section is disabled. Vault's was the accent and Mixture of Agents' the secondary label colour,
/// which barely dimmed beside its dimmed values. Off the Mac the label the page drew before.
struct MacAddRowLabel: View {
    var title: String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let _ = Theme.touch()
        if DeviceWord.isMac {
            let style = enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(MacField.dimmed)
            Label {
                Text(title).foregroundStyle(style)
            } icon: {
                Image(systemName: "plus").foregroundStyle(style)
            }
        } else {
            Label(title, systemImage: "plus")
        }
    }
}

/// [mac] Round 7: a cell of `MacAddRemoveButtons`, darkened while pressed.
private struct MacAddRemoveCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.hqLabel.opacity(0.1) : Color.clear)
    }
}

// MARK: - Buttons and option rows

extension View {
    /// [mac] #51: a row that is only a button (Sign Out, Add Gateway…, Export Settings…) is a push button at the
    /// trailing edge of its row on the Mac, not a full-width row in link colour. Elsewhere the row as it was.
    /// `leading`: the button is the row (Add Gateway… under a list's rows), at the form's leading edge as a Mac list's
    /// add button is, not alone at the trailing end of an empty row (review).
    @ViewBuilder func hqMacPushButton(leading: Bool = false, destructive: Bool = false) -> some View {
        if DeviceWord.isMac {
            HStack {
                if !leading { Spacer(minLength: 0) }
                self.buttonStyle(MacPushButtonStyle(kind: destructive ? .destructive : .plain))   // [mac] #55 (round 6)
                if leading { Spacer(minLength: 0) }
            }
        } else {
            self
        }
    }

    /// [mac] Stress test 2026-10-28 #51 (review): a form's own button (Sign Out, Add Gateway…, Restart Gateway…) as a
    /// Mac form draws it: a push button standing on the page under the card above, at the form's leading edge, with no
    /// card of its own (it was alone at the trailing end of an empty card). Put it alone in its section. A destructive
    /// one is red in both looks (the Desktop Look's page tint drew Sign Out blue). Elsewhere the row as it was.
    @ViewBuilder func hqMacFormButton(destructive: Bool = false) -> some View {
        if DeviceWord.isMac {
            HStack {
                self.buttonStyle(MacPushButtonStyle(kind: destructive ? .destructive : .plain))   // [mac] #55 (round 6)
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // [mac] Stress test 2026-10-28 round 6: on the form's text column (the rows' and footers' 20 pt inset), not
            // at the cards' edge 20 pt left of the footer above it.
            .listRowInsets(EdgeInsets(top: 0, leading: MacInset.side, bottom: 0, trailing: 0))
            .hqDesktopBareRow()
        } else {
            self
        }
    }

    /// [mac] #7 (review): a text field with the Mac's field box: a visible border and fill in both looks (the Desktop
    /// Look dark drew `.roundedBorder` as pure black with almost no edge).
    @ViewBuilder func hqMacFieldBox() -> some View {
        let _ = Theme.touch()
        if !DeviceWord.isMac {
            self.textFieldStyle(.roundedBorder)
        } else {
            // [mac] Stress test 2026-10-28 round 8: the pop-up's height (`MacForm.controlHeight`); the field's own 4 pt
            // above and under its text made it 34 pt beside 32 pt pop-ups.
            self.textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .frame(minHeight: MacForm.controlHeight)
            .background(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).fill(MacField.fill))
            .overlay(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).strokeBorder(MacField.stroke, lineWidth: 1))
        }
    }
}

/// [mac] #7 (review): the Mac's field and pop-up box, one look for both.
@MainActor enum MacField {
    static let radius: CGFloat = 5
    static var fill: Color { Theme.isDesktop ? Color.hqFill3 : Color.hqGroupedCard }
    static var stroke: Color { Color.hqLabel3.opacity(Theme.isDesktop ? 0.7 : 0.5) }
    /// A placeholder in the dimmed colour (the system's was too dim to read in the Desktop Look dark).
    static func prompt(_ text: String) -> Text { Text(text).foregroundStyle(dimmed) }
    /// [mac] Stress test 2026-10-28 round 8: a placeholder, a disabled value and a switched-off row's words: plainly dimmer
    /// than a value, and 3:1 or better on the card. The Desktop Look's third label colour reads at that already. The
    /// iOS look's (the ink at 36 %) was about 2.2:1 on the white card ("Main Model", "Not Signed In"); there it is the
    /// label colour at 55 %, about 3.4:1 on white. HQPalette is unchanged, so the iPhone keeps its colours.
    static var dimmed: Color { Theme.isDesktop ? Color.hqLabel3 : Color.hqLabel.opacity(0.55) }
}

/// [mac] Stress test 2026-10-28 round 8: a pop-up button's press. `.plain` faded a disabled pop-up as a whole on top of
/// its face's own dimmed colours, to about 2.3:1 (Mixture of Agents' models); the face dims itself (`MacPopUpFace`).
struct MacPopUpButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// [mac] #51, #7 (review): a pop-up button's face: the value and the up-down chevrons in a bordered box, so it reads as
/// a control (a menu picker drew plain text about 10 pt right of the value column). Also the face of a button that
/// opens a long chooser (a model) in a sheet.
struct MacPopUpFace: View {
    var text: String
    /// [mac] Stress test 2026-10-28 round 7: disabled, the value is in the secondary label colour and the chevrons in
    /// the third, readable (about 3:1 or better), not faded to near nothing.
    /// [mac] Round 8: both in the one dimmed colour (`MacField.dimmed`), which the button no longer fades again.
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let _ = Theme.touch()
        HStack(spacing: 6) {
            Text(text)
                .foregroundStyle(enabled ? Color.hqLabel : MacField.dimmed)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(Font.hq(.caption2).weight(.semibold))
                .foregroundStyle(enabled ? Color.hqLabel2 : MacField.dimmed)
                .accessibilityHidden(true)
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .frame(minHeight: MacForm.controlHeight)   // [mac] Stress test 2026-10-28 round 8: one height with the fields
        .background(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).fill(MacField.fill))
        .overlay(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).strokeBorder(MacField.stroke, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// [mac] #51: a pop-up button for a closed list, its menu checking the current value.
struct MacPopUp<Value: Hashable>: View {
    var label: String
    @Binding var selection: Value
    var options: [Value]
    var title: (Value) -> String

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in Text(title(option)).tag(option) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MacPopUpFace(text: title(selection))
        }
        .menuStyle(.button)
        .buttonStyle(MacPopUpButtonStyle())   // [mac] Stress test 2026-10-28 round 8
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}

/// [mac] #51 (review): a button that opens a long chooser (a model) as a sheet, drawn as a pop-up button.
struct MacChooserButton: View {
    var label: String
    var value: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { MacPopUpFace(text: value) }
            .buttonStyle(MacPopUpButtonStyle())   // [mac] Stress test 2026-10-28 round 8
            .fixedSize()
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// [mac] Stress test 2026-10-28 #51 (review): the › on a row that opens a page. The Mac draws none (a Mac form's row that
/// opens a page has no chevron; the Settings root's source list already had none), on every Settings page alike; the
/// iPhone and iPad keep iOS's chevron.
/// [mac] Stress test 2026-10-28 #51 (round 6): with none, rows that open a page had nothing to say so ("How Voice Works",
/// About's "Diagnostics", which read as a section label, the key rows, Status & Maintenance's "Recent Logs"). The Mac now draws
/// the quiet chevron System Settings has on such rows: small, in the third label colour (`MacChevron`).
struct SettingsChevron: View {
    var body: some View {
        if DeviceWord.isMac {
            MacChevron()
        } else {
            Image(systemName: "chevron.right")
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
        }
    }
}

/// [mac] #51 (round 6): the Mac's quiet › on a row that opens a page, in SwiftUI (`MacChevron.image` for UIKit rows).
struct MacChevron: View {
    var body: some View {
        let _ = Theme.touch()
        Image(systemName: "chevron.right")
            .font(Font.hq(.caption2).weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(Color.hqLabel3)
            .accessibilityHidden(true)
    }

    /// The same chevron for a UIKit row (`UICellAccessory.hqDisclosure()`, `UITableViewCell.hqDisclosure()`).
    @MainActor static var image: UIImage? {
        UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.caption2), scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold)))
    }

    /// The chevron in a view of its own, in the third label colour.
    @MainActor static func view() -> UIImageView {
        let view = UIImageView(image: image)
        view.tintColor = HQPalette.label3
        view.isAccessibilityElement = false
        return view
    }
}

extension UICellAccessory {
    /// A row that opens a page: iOS's disclosure chevron, [mac] #51 (round 6) the Mac's quiet one (`MacChevron`).
    @MainActor static func hqDisclosure() -> UICellAccessory {
        guard DeviceWord.isMac else { return .disclosureIndicator() }
        return .customView(configuration: .init(customView: MacChevron.view(), placement: .trailing(), reservedLayoutWidth: .actual,
                                                maintainsFixedSize: true))
    }
}

extension UITableViewCell {
    /// A row that opens a page: iOS's disclosure chevron, [mac] #51 (round 6) the Mac's quiet one (`MacChevron`).
    @MainActor func hqDisclosure(_ on: Bool = true, keepsRoom: Bool = false) {
        guard DeviceWord.isMac else { accessoryType = on ? .disclosureIndicator : .none; return }
        accessoryType = .none
        // [mac] Stress test 2026-10-31: `keepsRoom` holds the chevron's place on a row without one, so a column of
        // trailing values (Files' kinds) ends at one edge on every row, not past the chevron on files only.
        // Mac polish #112: the room is an empty view the chevron's size. A hidden chevron (alpha 0) came back on every
        // file row: the cell resets its accessory's alpha.
        if on {
            accessoryView = MacChevron.view()
        } else if keepsRoom {
            accessoryView = UIView(frame: CGRect(origin: .zero, size: MacChevron.image?.size ?? .zero))
        } else {
            accessoryView = nil
        }
    }
}

/// [mac] #51: one choice in an option list. On the Mac a radio button leads and the name is in the label colour (the
/// names were link blue and the choice a ✓ about 680 pt away); elsewhere the name and a trailing ✓, as before.
struct HQOptionRowLabel: View {
    var title: String
    var selected: Bool

    var body: some View {
        // [mac] Stress test 2026-10-28 #51 (round 6): one size on every page (the app's body, not the host's: a page
        // hosted outside HQScaledRoot drew the system body, about 14 px against 16) and the radio on the first line.
        HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
            if DeviceWord.isMac {
                HQRadioMark(selected: selected)
            }
            Text(title).foregroundStyle(Color.hqLabel)
                .font(Font.hq(.body))
            Spacer()
            if !DeviceWord.isMac, selected {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.hqTint)
            }
        }
        .padding(.vertical, DeviceWord.isMac ? 0 : 4)
        .contentShape(Rectangle())
    }
}

/// [mac] #51: a whole number typed in place with its unit, kept in `range` (Largest Attachment's 1…32 MB was a page of
/// its own with iOS's "− | +" stepper). Out of range is brought into it, not refused; anything else is put back.
struct MacIntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String
    var label: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text, prompt: MacField.prompt(label))
                .multilineTextAlignment(.leading)   // [mac] Stress test 2026-10-28 round 8: as the column's pop-ups
                .monospacedDigit()
                .keyboardType(.numberPad)
                .hqMacFieldBox()
                // [mac] Stress test 2026-10-28 round 9: every number field's one width (32 MB's was 88 against 125).
                .frame(width: MacForm.numberWidth)
                .focused($focused)
                .onSubmit(save)
                .accessibilityLabel(label)
            Text(unit).foregroundStyle(Color.hqLabel2)
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, now in if !focused { text = String(now) } }
        .onChange(of: focused) { _, now in if !now { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        guard let typed = Int(text.trimmingCharacters(in: .whitespaces)) else { text = String(value); return }
        let next = min(max(typed, range.lowerBound), range.upperBound)
        text = String(next)
        if next != value { value = next }
    }
}

/// [mac] #51 (review): the leading radio of a choice row with more than a title (a hint under it, a model's ID): on the
/// Mac only; elsewhere nothing (the row keeps its trailing ✓, `HQCheckMark`).
struct HQRadioMark: View {
    var selected: Bool
    var body: some View {
        if DeviceWord.isMac {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(Font.hq(.body))   // [mac] Stress test 2026-10-28 #51 (round 6): the title's size on every page
                .foregroundStyle(selected ? Color.hqTint : Color.hqLabel3)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// [mac] Stress test 2026-10-28 #51 (round 6): a radio group's rows have no rules between them on the Mac (a Mac's
    /// radio group is one control); elsewhere unchanged.
    @ViewBuilder func hqRadioRow() -> some View {
        if DeviceWord.isMac { listRowSeparator(.hidden) } else { self }
    }
}

/// The trailing ✓ of a chosen row off the Mac; nothing on the Mac, where `HQRadioMark` leads the row.
struct HQCheckMark: View {
    var selected: Bool
    var body: some View {
        if !DeviceWord.isMac, selected {
            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.hqTint)
        }
    }
}

private struct HQSourceListRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// [mac] #51: rows in a source list (the Settings root): no › chevron on the Mac.
    var hqSourceListRows: Bool {
        get { self[HQSourceListRowsKey.self] }
        set { self[HQSourceListRowsKey.self] = newValue }
    }
}
