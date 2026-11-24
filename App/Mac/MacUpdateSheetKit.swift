// [Mac calls 2026-11-17] Owner's call (Q20): "one look for updates". The Mac app's own update window
// (MacAppUpdate.swift) and, on the Mac, Update Hermes (HermesUpdate.swift) and Update Add-on (AddOnUpdate.swift, the
// plugin update too) are drawn from these pieces, lifted out of MacAppUpdate.swift so the three sheets cannot drift
// apart: a 540 pt sheet sized to its content; a header with a small icon beside the headline and its lines; cards for
// the steps and What's New; one step row; a hairline; the Mac's button row (the default button last, on the right).
// iPhone and iPad keep their own sheets.

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// The height a sheet has on the window (the window less the sheet's margins). Its controller keeps it current; the
/// sheet's middle (steps, What's New) scrolls when the whole would be taller, so the buttons stay on the window.
@MainActor @Observable final class MacUpdateRoom {
    var height: CGFloat = .greatestFiniteMagnitude

    func read(_ controller: UIViewController) {
        guard let window = controller.presentingViewController?.viewIfLoaded?.window ?? controller.viewIfLoaded?.window else { return }
        let room = max(320, window.bounds.height - 80)
        if abs(room - height) > 1 { height = room }
    }
}

/// The sheet: header, the middle (when there is one), a hairline, the buttons.
struct MacUpdateSheet<Header: View, Middle: View, Buttons: View>: View {
    var room: MacUpdateRoom?
    var showsMiddle: Bool
    @ViewBuilder var header: Header
    @ViewBuilder var middle: Middle
    @ViewBuilder var buttons: Buttons

    static var width: CGFloat { 540 }

    @State private var headerHeight: CGFloat = 0
    @State private var middleHeight: CGFloat = 0
    @State private var footHeight: CGFloat = 0

    var body: some View {
        let _ = Theme.touch()
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            if showsMiddle {
                let content = VStack(alignment: .leading, spacing: 14) { middle }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
                Group {
                    if let cap, middleHeight > cap + 1 {
                        ScrollView { content }.frame(height: cap)
                    } else {
                        content
                    }
                }
                .transition(.hqMotion(.opacity))
            }
            // [Mac AAA 2026-11-16] On whole screen pixels: `Divider()` fell between pixels at the Mac's 77 % and blurred.
            MacUpdateHairline()
            HStack(spacing: 10) { buttons }
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footHeight = $0 }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.hqGroupedPage.ignoresSafeArea())
    }

    /// The middle's most, when the window is shorter than the whole sheet.
    private var cap: CGFloat? {
        guard let room, room.height < .greatestFiniteMagnitude else { return nil }
        return max(120, room.height - headerHeight - footHeight - 1)
    }
}

/// The header: a 64 pt icon column, then the headline over its lines (versions, where, what happens).
struct MacUpdateHeader<Icon: View, Lines: View>: View {
    var headline: String
    var headlineID: String
    @ViewBuilder var icon: Icon
    @ViewBuilder var lines: Lines

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(Font.hq(.title3).weight(.hqBold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(headlineID)
                lines
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentTransition(.opacity)
    }
}

/// "1.0.4 (5) → 1.0.2 (925)" under the headline.
struct MacUpdateVersions: View {
    var text: String
    var id: String

    var body: some View {
        Text(text)
            .font(Font.hq(.subheadline).weight(.medium).monospacedDigit())
            .foregroundStyle(Color.hqLabel)
            .accessibilityLabel(text.replacingOccurrences(of: "→", with: "to"))
            .accessibilityIdentifier(id)
    }
}

/// A line under the headline: what happens, in the quiet ink.
struct MacUpdateLine: View {
    var text: String
    var id: String

    var body: some View {
        Text(text)
            .font(Font.hq(.subheadline))
            .foregroundStyle(Color.hqLabel2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }
}

/// The gateway sheets' icon: their state's own symbol (a spinner while there is none), in the icon's column.
struct MacUpdateSymbol: View {
    var symbol: (name: String, color: Color)?

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol.name)
                    .font(Font.hq(.largeTitle))
                    .foregroundStyle(symbol.color)
                    .transition(.hqMotion(.scale.combined(with: .opacity)))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(width: 64, height: 64)
    }
}

extension View {
    /// The update sheets' card: the grouped card fill and an even hairline, on the look's corner.
    func macUpdateCard() -> some View {
        // [Mac AAA 2026-11-16] The cards take the look's corner (`HQShape.radius`): the Desktop Look's 4 pt, not 10 pt
        // beside its square-cornered buttons and sheets.
        background(RoundedRectangle(cornerRadius: HQShape.radius(10, .card), style: .continuous).fill(Color.hqGroupedCard))
            .overlay(RoundedRectangle(cornerRadius: HQShape.radius(10, .card), style: .continuous).strokeBorder(Color.hqStroke, lineWidth: HQShape.line(0.5)))
    }
}

/// The steps' card: a row per step, hairlines between them inset to the titles. Each row's line sits on its right; when
/// one of them doesn't fit there (Update Hermes's "Bots finish the replies they're working on first…"), every row of the
/// card puts its line under its title instead (a time stays on the right), so one card never mixes the two.
struct MacUpdateStepsCard<Item: Identifiable, Row: View>: View {
    var items: [Item]
    var id: String
    /// The row; its `Bool`: lines under the titles.
    @ViewBuilder var row: (Item, Bool) -> Row

    var body: some View {
        ViewThatFits(in: .horizontal) {
            card(below: false)
            card(below: true)
        }
        .macUpdateCard()
        .accessibilityIdentifier(id)
    }

    private func card(below: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { MacUpdateHairline().padding(.leading, 44) }
                row(item, below)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A step's mark.
enum MacUpdateMark: Equatable {
    case waiting, active, done, skipped, failed

    var spoken: String {
        switch self {
        case .done: "Done"
        case .active: "In progress"
        case .skipped: "Not needed"
        case .failed: "Failed"
        case .waiting: "Waiting"
        }
    }
}

/// One step: its mark, its title, and its line on the right (`below`: under the title, unless it is a finished step's
/// time).
struct MacUpdateStepRow: View {
    var mark: MacUpdateMark
    var title: String
    var detail: String?
    var below = false
    /// "mac-update", "hermes-update", "addon-update": the identifiers' first part.
    var idPrefix: String
    var stepID: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                switch mark {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hqGreen)
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                case .active:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Color.hqLabel3)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(Color.hqLabel3)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.hqRed)
                }
            }
            .font(Font.hq(.body))
            .frame(width: 20, height: 20)
            if below && mark != .done {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    if let detail { detailText(detail).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                titleText
                Spacer(minLength: 12)
                if let detail { detailText(detail).lineLimit(1).fixedSize() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move)), value: mark)
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move), fades: true), value: detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(mark.spoken)
        .accessibilityIdentifier("\(idPrefix).step.\(stepID)")
    }

    private var titleText: some View {
        Text(title)
            .font(Font.hq(.body).weight(mark == .active ? .semibold : .regular))
            .foregroundStyle(mark == .waiting || mark == .skipped ? Color.hqLabel2 : Color.hqLabel)
            .lineLimit(1)
            .fixedSize()
    }

    private func detailText(_ words: String) -> some View {
        Text(words)
            .font(Font.hq(.footnote).monospacedDigit())
            .foregroundStyle(mark == .failed ? Color.hqRed : Color.hqLabel2)
            .contentTransition(.opacity)
            .accessibilityIdentifier("\(idPrefix).detail.\(stepID)")
    }
}

/// What's New: a quiet heading over a card of bullet lines (a long list scrolls in a fixed box).
struct MacUpdateNotes: View {
    var title: String
    var intro: String?
    var items: [String]
    var id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
            let list = VStack(alignment: .leading, spacing: 7) {
                if let intro {
                    Text(intro).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
                        Text(item).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 14).padding(.bottom, 14)
            .padding(.leading, 14).padding(.trailing, 14 + (items.count > 6 ? ScrollBarLane.listTrailing : 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                // A long list scrolls in a fixed box; a short one is drawn whole.
                if items.count > 6 {
                    ScrollView { list }.frame(height: 260)
                } else {
                    list
                }
            }
            .macUpdateCard()
        }
        .accessibilityIdentifier(id)
    }
}

/// A quiet footnote in the button row (the countdown, "Back in a few seconds", "1:15 so far").
struct MacUpdateFootnote<Words: View>: View {
    @ViewBuilder var words: Words

    var body: some View {
        words
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
    }
}

/// "1:15 so far", ticking.
struct MacUpdateElapsed: View {
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            MacUpdateFootnote {
                Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(since))))) so far").monospacedDigit()
            }
        }
        .accessibilityHidden(true)
    }
}

/// A push button of the row: the filled one is the sheet's default (Return presses it).
/// [macpass-sidebar] A button title never wraps: with four buttons (Copy Details, Open Website, Done, Try Again on
/// "The Update Wasn't Signed Right") SwiftUI squeezed Copy Details onto two lines; the row has room for all four at
/// their natural width, so each title keeps its one line.
struct MacUpdateButton: View {
    var title: String
    var id: String
    var prominent = false
    var perform: () -> Void

    var body: some View {
        Group {
            if prominent {
                Button(action: perform) { Text(title).lineLimit(1).fixedSize().frame(minWidth: 72) }
                    .hqProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(action: perform) { Text(title).lineLimit(1).fixedSize().frame(minWidth: 60) }
                    .hqBorderedButtonStyle()
            }
        }
        .accessibilityIdentifier(id)
    }
}

/// [Mac AAA 2026-11-16] The update window's rules: the stroke colour on whole screen pixels (`HQShape.hairline`), as
/// `SettingsHairline` draws Settings' (SwiftUI's `Divider()` drew a soft 0.77 px line here).
struct MacUpdateHairline: View {
    var body: some View {
        HQHairline(color: .hqStroke)
    }
}

/// The Mac's gateway update sheets' controller: a fitted form sheet as the Mac app's own (`MacAppUpdateController`),
/// keeping its room current. `closed`: the sheet went (Escape, a button, the window closing).
class MacUpdateSheetController<Root: View>: UIHostingController<HQScaledRoot<Root>> {
    let room: MacUpdateRoom
    private let closed: () -> Void

    init(room: MacUpdateRoom, root: Root, closed: @escaping () -> Void) {
        self.room = room
        self.closed = closed
        super.init(rootView: HQScaledRoot(root))
        modalPresentationStyle = .formSheet
        sizingOptions = [.preferredContentSize]
        isModalInPresentation = false
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        room.read(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        room.read(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { closed() }
    }
}
#endif
