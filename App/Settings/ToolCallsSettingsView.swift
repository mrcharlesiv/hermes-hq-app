import SwiftUI
import UIKit

// Settings › Chat › Tool Calls (docs/spec/1x-activity.md §13): Tool Call Style (Rows · One Line · At the Bottom · Bubbles · In Header) and Tool
// Calls After Reply (Keep · Hide, hidden under In Header). Device-local; every change plays a selection tick and applies
// to open chats at once. Tool Call Style is a checkmark list, each option with its own line (UX study 2026-10-21 #111).
// Segment labels are never cut (M:segmented-labels-whole.md): when After Reply's don't fit — always at accessibility
// sizes — its options are a checkmark list too.
//
// Integration: the settings stream shows the row once these are set at launch —
//   SettingsHooks.toolCallsScreen = { ToolCallsSettings.makeScreen() }
//   SettingsHooks.toolCallsSummary = { ToolCallSettings.summary }

extension ToolCallSettings {
    /// `inSheet`: [mac] Stress test 2026-10-28 round 9: shown in a chat's sheet, whose rows are a sheet's one-line rows
    /// (about 45 pt, as Chat Info's), not the Settings page's.
    @MainActor static func makeScreen(inSheet: Bool = false) -> UIViewController {
        let host = UIHostingController(rootView: HQScaledRoot(ToolCallsSettingsView(inSheet: inSheet)))
        host.title = "Tool Calls"
        host.navigationItem.largeTitleDisplayMode = .never
        return host
    }
}

struct ToolCallsSettingsView: View {
    var inSheet = false
    @State private var style = ToolCallSettings.style
    @State private var afterReply = ToolCallSettings.afterReply
    @Environment(\.dynamicTypeSize) private var typeSize

    // UX study #110: one sentence ties "tool calls" to "steps". #111 (2026-10-21): what each style does is on its own
    // row (ToolCallStyle.detail), so the footer keeps only what they share.
    static let styleFooter = "Each tool call shows as a step. \(DeviceWord.Tap) a line of steps to list them."
    static let afterReplyFooter = "Hide shows each step while the bot works, then clears them when it replies (as in Telegram). A step that failed stays. To see a reply’s steps again, \(DeviceWord.hold) it and choose Show Steps."

    var body: some View {
        Form {
            Section {
                checkmarks(ToolCallStyle.allCases, selection: $style, title: \.title, detail: \.detail, id: "settings.tool-call-style")
            } header: { HQSectionLabel {
                Text("Tool Call Style")
            } } footer: { HQSectionFooter {
                Text(Self.styleFooter)
            } }
            if style != .header {
                Section {
                    options("Tool Calls After Reply", ToolCallsAfterReply.allCases, selection: $afterReply, title: \.title,
                            id: "settings.tool-calls-after-reply")
                } header: { HQSectionLabel {
                    Text("Tool Calls After Reply")
                } } footer: { HQSectionFooter {
                    Text(Self.afterReplyFooter)
                } }
            }
        }
        // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches. Round 9: on the Settings
        // page its rows are the page's one row height; in a chat's sheet the form's (`MacForm.rowHeight`).
        .hqMacForm(settings: !inSheet)
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .onChange(of: style) { _, value in
            ToolCallSettings.style = value
            AppLog.note("settings", "tool call style set to \(value)")
            Haptics.play(.selection)
        }
        .onChange(of: afterReply) { _, value in
            ToolCallSettings.afterReply = value
            AppLog.note("settings", "tool calls after reply set to \(value)")
            Haptics.play(.selection)
        }
        .navigationTitle("Tool Calls")
    }

    @ViewBuilder
    private func options<T: Hashable>(_ label: String, _ values: [T], selection: Binding<T>, title: KeyPath<T, String>, id: String) -> some View {
        // [mac] Stress test 2026-10-28 #73: on the Mac both settings are radio groups; a two-choice segmented control
        // in a card of its own read as a second, different kind of control.
        let fits = !DeviceWord.isMac && !typeSize.isAccessibilitySize && SegmentFit.fits(values.map { $0[keyPath: title] })
        if fits {
            HQSegmentedPicker(label, options: values.map { ($0[keyPath: title], $0) }, selection: selection)   // [desktoplook3]
            .labelsHidden()
            .padding(.vertical, 6)
            .accessibilityIdentifier(id)
        } else {
            checkmarks(values, selection: selection, title: title, detail: nil, id: id)
        }
    }

    /// One row per option, the chosen one ticked; `detail` is a line under the name. The row is named by the option
    /// alone (UI tests and Voice Control find it by that); its line is the hint. [mac] Stress test 2026-10-28 #73: a
    /// radio group on the Mac: the button leads, the name is in the label colour over its grey line (the names were in
    /// link blue over full-strength lines, and the choice was a small ✓ out by the line).
    private func checkmarks<T: Hashable>(_ values: [T], selection: Binding<T>, title: KeyPath<T, String>, detail: KeyPath<T, String>?,
                                         id: String) -> some View {
        ForEach(values, id: \.self) { value in
            Button {
                selection.wrappedValue = value
            } label: {
                HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : 12) {
                    HQRadioMark(selected: selection.wrappedValue == value)   // [mac] Stress test 2026-10-28 #51 (round 6): the shared radio, one size
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value[keyPath: title]).foregroundStyle(DeviceWord.isMac ? AnyShapeStyle(Color.hqLabel) : AnyShapeStyle(.primary))
                            .font(Font.hq(.body))   // [mac] #51 (round 6): the app's body (this host drew the system body)
                        if let detail {
                            Text(value[keyPath: detail]).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if !DeviceWord.isMac, selection.wrappedValue == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                // [mac] Stress test 2026-10-28 round 9: on the Mac a row with a line under it is its lines and the list's
                // own room, as every Settings row with two lines is (no extra 4 pt).
                .hqRowPadding(detail == nil ? 0 : 4)
                .frame(minHeight: DeviceWord.isMac ? nil : 44)
                .contentShape(Rectangle())
            }
            // [mac] Stress test 2026-10-28 round 9: Keep and Hide are ordinary one-line rows. Round 8 took their row
            // insets away and drew them 31 pt tall (the words 5 pt under the card's top). On the Settings page they are
            // the page's one row height; in the chat's sheet the form's one-line row (`MacForm.rowHeight`, about 45 pt).
            .hqMacOneLineRow(detail == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value[keyPath: title])
            .accessibilityHint(detail.map { value[keyPath: $0] } ?? "")
            .accessibilityAddTraits(selection.wrappedValue == value ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("\(id).\(value[keyPath: title])")
            .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
        }
    }
}

private extension View {
    /// [mac] Stress test 2026-10-28 round 9: a one-line radio row is the form's one-line row (`hqMacFormRowHeight`); a
    /// style with its line under it keeps the list's own room.
    @ViewBuilder func hqMacOneLineRow(_ oneLine: Bool) -> some View {
        if oneLine { hqMacFormRowHeight() } else { self }
    }
}

/// Whether segment labels fit a row on this screen at the current text size (each segment equal width, 12 pt padding).
enum SegmentFit {
    @MainActor static func fits(_ labels: [String]) -> Bool {
        let font = HQFont.preferred(.subheadline)
        // [m9/ipad] In a pane or a resized window: the pane's width, not the screen's.
        let width = (ChatViewController.openingSize?.width ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }.first ?? 390) - 72
        let segment = width / CGFloat(max(1, labels.count))
        return labels.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width + 24 <= segment }
    }
}
