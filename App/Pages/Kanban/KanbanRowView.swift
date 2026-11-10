// Kanban pieces (docs/spec/1x-pages.md §4.3–§4.4): a task row (the assignee's robot head, the title, the meta line),
// a status chip, the board button and the empty chip state.

import SwiftUI
import UIKit

/// A status tone (`model.ts:35-38`).
enum KanbanTone {
    static func color(_ status: String) -> Color {
        switch status {
        case "blocked": return .hqRed   // the theme's red, as the blocked alert beside it
        case "triage": return .hqLabel3
        case "todo": return .hqLabel2
        case "scheduled": return Color(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255)
        case "ready": return Color(uiColor: .systemBlue)
        case "running": return Color(uiColor: .systemGreen)
        case "review": return .hqOrange
        case "done": return .hqLabel3
        default: return .hqLabel3
        }
    }
}

struct KanbanRowModel: Hashable {
    var id: String
    var title: String
    var assignee: String?
    var head: JSONValue?
    var bits: [Bit]

    struct Bit: Hashable { var text: String; var alert: Bool }

    /// The meta bits (`board-page.tsx` `rowMeta`): who, why blocked, no-one-assigned, running for, age, comments.
    static func bits(_ task: KanbanTask, fallback: String, botName: (String?) -> String, now: Date = Date()) -> [Bit] {
        let who = task.assignee ?? (task.status == "ready" && !fallback.isEmpty ? fallback : nil)
        var bits = [Bit(text: botName(who), alert: false)]
        if task.status == "blocked" { bits.append(Bit(text: KanbanModel.blockReason(task.blockKind), alert: true)) }
        if task.status == "ready" && task.assignee == nil && fallback.isEmpty {
            bits.append(Bit(text: "No one assigned, won’t run", alert: true))
        }
        if task.status == "running" {
            bits.append(Bit(text: "Running \(KanbanModel.shortAge(task.currentRunStartedAt ?? task.startedAt, now: now))".pgTrim, alert: false))
        }
        let age = KanbanModel.shortAge(task.status == "done" ? (task.completedAt ?? task.createdAt) : task.createdAt, now: now)
        if !age.isEmpty && task.status != "running" { bits.append(Bit(text: age, alert: false)) }
        if let count = task.commentCount, count > 0 { bits.append(Bit(text: "\(count) \(count == 1 ? "comment" : "comments")", alert: false)) }
        return bits
    }
}

struct KanbanRowView: View {
    var row: KanbanRowModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            face.padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title.isEmpty ? row.id : row.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(typeSize.isAccessibilitySize ? 6 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
            }
        }
        .padding(.vertical, Theme.isDesktop ? 13 : 10)   // [compact] iOS look: 3 pt less a side (owner 2026-10-17)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title). \(row.bits.map(\.text).joined(separator: ", "))")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var face: some View {
        if let who = row.assignee {
            HeadImage(raw: row.head, profile: who, size: HQFont.scaled(32))   // [ui-sizing] × UI Scale, as its title
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.hqLabel3, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
        }
    }

    /// Bits joined by " · ". The dot stays with the bit before it (a no-break space), so a bit that wraps starts its
    /// line with its own words, never with a dot (verify round 1: "· 2 comments" at XXL).
    private var meta: some View {
        PagesFlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(Array(row.bits.enumerated()), id: \.offset) { index, bit in
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(bit.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .fontWeight(bit.alert ? .semibold : .regular)
                        .foregroundStyle(bit.alert ? Color.hqRed : Color.hqLabel2)
                    if index < row.bits.count - 1 { Text("\u{00A0}·").foregroundStyle(Color.hqLabel2).layoutPriority(1) }
                }
                .font(Font.hq(.footnote))
            }
        }
    }
}

/// Wraps its children like text, `spacing` apart on a line.
struct PagesFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: width)
            if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    /// [a11y] A child wider than the whole line wraps inside it and takes the height it then needs (stress round 2:
    /// "Needs your…" was cut to one line at the largest text size). Everything else keeps its one-line size.
    static func size(of view: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard width.isFinite, width > 0, ideal.width > width else { return ideal }
        let wrapped = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(wrapped.width, width), height: wrapped.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: bounds.width)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A status chip: dot, label, count. Selected: tint fill 16 %, tint text. Blocked with tasks: red text.
struct KanbanChipView: View {
    var status: String
    var count: Int
    var selected: Bool
    /// [a11y] The pill's height: 36 pt, taller when the text is (`KanbanChipView.height(for:)`).
    var height: CGFloat = 36

    /// 36 pt at the standard sizes; at larger text the pill grows with its words (stress round 2: the text stood
    /// taller than the pill at the largest size). The chip row's layout uses the same number.
    static func height(for traits: UITraitCollection) -> CGFloat {
        max(36, ceil(HQFont.preferred(.subheadline, compatibleWith: traits).lineHeight) + 14)
    }

    var body: some View {
        let alert = status == "blocked" && count > 0 && !selected
        let textColor: Color = selected ? .hqTintText : alert ? .hqRed : count == 0 ? .hqLabel2 : .hqLabel
        HStack(spacing: 6) {
            Circle().fill(KanbanTone.color(status)).frame(width: 8, height: 8)
            Text(KanbanModel.label(status))
                .font(Font.hq(.subheadline).weight(count == 0 && !selected ? .regular : .semibold))
                .foregroundStyle(textColor)
            Text("\(count)")
                .font(Font.hq(.subheadline))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.hqTintText : alert ? Color.hqRed : Color.hqLabel2)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: height)
        .modifier(KanbanChipShape(selected: selected))   // [desktoplook2] outlined in the look
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(KanbanModel.label(status)), \(count) \(count == 1 ? "task" : "tasks")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// [desktoplook2] The chip's shape: iOS's filled capsule, or in the Desktop Look an outlined 3 pt box, the chosen
/// one on the active-row fill with the stronger stroke (phone-ui-desktop.css, kanban chips).
private struct KanbanChipShape: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        if Theme.isDesktop {
            content
                .background(selected ? Color(uiColor: HQPalette.cellPressed) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Color.hqTintText : Color.hqStroke, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 3))
        } else {
            content
                .background(Capsule().fill(selected ? Color.hqTint.opacity(0.16) : Color.hqFill3))
                .contentShape(Capsule())
        }
    }
}

/// An empty status: the board glyph, "Nothing in <Status>", its help line and New Task (not for locked statuses or Done).
/// A board with no tasks at all: "No Tasks Yet" (`wholeBoard`).
struct KanbanEmptyView: View {
    static let wholeBoard = "*board"
    var status: String
    var query: String
    var newTask: (() -> Void)?
    /// [mac] Stress test 2026-10-28 #9: the room above, so the state sits where every page's does (40 elsewhere).
    var top: CGFloat = 40

    var body: some View {
        // [mac] Stress test 2026-10-28 #52: the Mac's one empty-state symbol, title and line (MacType).
        let symbol: CGFloat = HQFont.scaled(34)
        VStack(spacing: 8) {
            Image(uiImage: PagesTabIcons.kanban)
                .renderingMode(.template)
                .resizable()
                .frame(width: symbol, height: symbol)
                .foregroundStyle(Color.hqLabel3)
                .padding(.bottom, 4)
            // [mac] Stress test 2026-10-31: the Mac's fonts in place of the phone's, not after them (a Text's own font
            // wins over one set around it, so the iOS look's title stayed Headline, smaller than every other state's).
            Text(title)
                .font(DeviceWord.isMac ? MacType.emptyTitleFont : Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
            Text(help)
                .font(DeviceWord.isMac ? MacType.emptyBodyFont : Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
            if let newTask, query.isEmpty {
                Button("New Task…", action: newTask)
                    .hqEmptyActionButtonStyle(glass: true)   // [mac] Stress test 2026-10-28 #55 (round 6): the plain push button on the Mac
                    .padding(.top, 8)
                    .accessibilityIdentifier("kanban.empty.new")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, top)
        .padding(.bottom, 40)
        .padding(.horizontal, 24)
    }

    private var title: String {
        if !query.isEmpty { return "No Results for “\(query)”" }
        return status == Self.wholeBoard ? "No Tasks Yet" : "Nothing in \(KanbanModel.label(status))"
    }

    private var help: String {
        // [mac-tools] The Mac's board searches every status at once.
        if !query.isEmpty { return status == Self.wholeBoard ? "Try another word." : "Try another word, or another status." }
        return status == Self.wholeBoard ? "Tasks you and your bots add to this board show here." : KanbanModel.statusHelp[status] ?? ""
    }
}

/// "Loading…" with a spinner, or the board's failure with Try Again.
struct KanbanStatusView: View {
    var loading: Bool
    var error: String?
    var retrying: Bool
    var retry: () -> Void

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t Load the Board").font(Font.hq(.body))
                    // The gateway's own reason, in the card: a fixed red "Check your connection" sat over it for an
                    // auth or server error too, and the reason hung below the card in an overlay that took no room.
                    Text(error).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
                Divider().padding(.leading, 16)
                Button(retrying ? "Trying…" : "Try Again", action: retry)
                    .disabled(retrying)
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: HQShape.radius(26, .card), style: .continuous).fill(Color.hqFill3))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…").foregroundStyle(Color.hqLabel2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}
