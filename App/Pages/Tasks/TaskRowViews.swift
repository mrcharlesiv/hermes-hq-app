// [tasks] The Tasks page's rows (owner-approved mockup 1-list, 2026-11-04): a circle to tick for your tasks (a bot's
// own task leads with its face instead), the title, and one line whose start is coloured by where the task stands
// (Ready green, the bot at work blue, Needs you orange, Overdue red); a together task carries the bot's small face at
// its end. Sizes as the Jobs rows (20 pt in, 22 pt faces centred on the title's first line).

import SwiftUI
import UIKit

/// The words' colours.
enum TodoInk {
    /// Ready: a green that reads as text (iOS's own green is 2.2:1 on white).
    static let ready = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            : UIColor(red: 0.11, green: 0.50, blue: 0.22, alpha: 1)
    }

    static func color(_ tone: TodoTone) -> Color {
        switch tone {
        case .ready: return Color(uiColor: ready)
        case .working: return Color.hqTintText
        case .needsYou: return Color.hqOrange
        case .overdue: return Color.hqRed
        case .plain: return Color.hqLabel2
        }
    }
}

/// [mac-tools] The Mac table's column widths.
enum TodoTable {
    static let status: CGFloat = 190, details: CGFloat = 330, who: CGFloat = 180
}

struct TodoRowModel: Hashable {
    var id: String
    var title: String
    var line: TodoRowLine
    var done: Bool
    /// Ticked here and about to move to Done.
    var ticking = false
    /// A bot's own task: its face leads (no circle).
    var leadFace: String?
    /// A together task: the bot's face at the end.
    var trailFace: String?
    var head: JSONValue?
    /// Select: the lead is a pick circle (filled when `picked`), the whole row toggles it.
    var selecting = false
    var picked = false
    /// [mac-tools] The Mac's table over the window: the row is one line of columns.
    var wide = false
    /// Who has it ("You", the bot, "You & the bot"): the table's last column.
    var who = ""
}

struct TodoRowView: View {
    var row: TodoRowModel
    var toggle: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var textFaceSize: CGFloat = 22
    /// [ui-sizing] × UI Scale too: a ScaledMetric follows only the text size, and at 150 % the text grew around it.
    private var faceSize: CGFloat { HQFont.scaled(textFaceSize) }
    @ScaledMetric(relativeTo: .callout) private var textCircleSize: CGFloat = 22
    /// [ui-sizing] × UI Scale too: a ScaledMetric follows only the text size, and at 150 % the text grew around it.
    private var circleSize: CGFloat { HQFont.scaled(textCircleSize) }
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        if row.wide { table } else { list }
    }

    /// [mac-tools] The table's row: the task, where it stands (in its colour), the details, who has it.
    private var table: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            lead
            Text(row.title)
                .font(Font.hq(.callout))
                .foregroundStyle(row.done || row.ticking ? Color.hqLabel2 : Color.hqLabel)
                .strikethrough(row.done || row.ticking, color: Color.hqLabel3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.line.lead ?? "")
                .font(Font.hq(.subheadline).weight(.medium)).foregroundStyle(TodoInk.color(row.line.tone))
                .lineLimit(1)
                .frame(width: TodoTable.status, alignment: .leading)
            Text(row.line.rest.joined(separator: " · "))
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                .frame(width: TodoTable.details, alignment: .leading)
            HStack(spacing: 7) {
                if let profile = row.trailFace {
                    HeadImage(raw: row.head, profile: profile, size: 18).frame(width: 18, height: 18)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.subheadline).capHeight / 2 }
                }
                Text(row.who).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            .frame(width: TodoTable.who, alignment: .leading)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .frame(minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.line.text), \(row.who)")
        .accessibilityValue(row.done ? "Done" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: row.done ? "Mark Not Done" : "Mark Done") { toggle() }
    }

    private var list: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Font.hq(.callout))
                    .foregroundStyle(row.done || row.ticking ? Color.hqLabel2 : Color.hqLabel)
                    .strikethrough(row.done || row.ticking, color: Color.hqLabel3)
                    .lineLimit(large ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !row.line.text.isEmpty {
                    line
                        .font(Font.hq(.footnote))
                        .lineLimit(large ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let profile = row.trailFace {
                face(profile)
            }
        }
        .padding(.vertical, Theme.isDesktop ? 12 : 9)
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(minHeight: Theme.isDesktop ? 56 : 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.line.text)")
        .accessibilityValue(row.done ? "Done" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: row.done ? "Mark Not Done" : "Mark Done") { toggle() }
    }

    @ViewBuilder private var lead: some View {
        if row.selecting {
            let size = min(30, circleSize).rounded()
            Image(systemName: row.picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: row.picked ? .regular : .light))
                .foregroundStyle(row.picked ? Color.hqTint : Color.hqLabel3)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.callout).capHeight / 2 }
                .accessibilityHidden(true)
        } else if let profile = row.leadFace {
            face(profile)
        } else {
            Button(action: toggle) {
                let size = min(30, circleSize).rounded()
                Image(systemName: row.done || row.ticking ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size, weight: .light))
                    .foregroundStyle(row.done || row.ticking ? Color.hqTint : Color.hqLabel3)
                    .frame(width: size, height: size)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.callout).capHeight / 2 }
            .accessibilityHidden(true)
            .accessibilityIdentifier("tasks.circle.\(row.id)")
        }
    }

    private func face(_ profile: String) -> some View {
        let size = min(32, faceSize).rounded()
        return HeadImage(raw: row.head, profile: profile, size: size)
            .frame(width: size, height: size)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.callout).capHeight / 2 }
            .accessibilityHidden(true)
    }

    private var line: Text {
        let rest = Text(row.line.rest.joined(separator: " · ")).foregroundStyle(Color.hqLabel2)
        guard let lead = row.line.lead else { return rest }
        let colored = Text(lead).foregroundStyle(TodoInk.color(row.line.tone))
        return row.line.rest.isEmpty ? colored : Text("\(colored)\(Text(" · ").foregroundStyle(Color.hqLabel2))\(rest)")
    }
}

/// A section's header: "Ready for You 2" with the green sparkle, "Needs You" with an orange hand, Done with Hide.
struct TodoSectionHeaderView: View {
    var section: TodoSection
    var count: Int
    var open: Bool
    var toggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
            if section == .stale {
                // Why these are here, and what to do (swipe or hold a row for Keep).
                Text(TodoWords.staleNote)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.stale.note")
            }
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            switch section {
            case .ready:
                Image(systemName: "sparkles").foregroundStyle(Color(uiColor: TodoInk.ready)).font(Font.hq(.subheadline).weight(.semibold))
            case .needsYou:
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.hqOrange).font(Font.hq(.subheadline))
            case .overdue:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.hqRed).font(Font.hq(.subheadline))
            case .stale:
                Image(systemName: "questionmark.circle").foregroundStyle(Color.hqLabel2).font(Font.hq(.subheadline))
            default:
                EmptyView()
            }
            if section == .ready, !Theme.isDesktop {
                // Mockup 1-list: "Ready for You 2" in the sparkle's green.
                let number = Text("\(count)").font(Font.hq(.subheadline)).monospacedDigit()
                Text("\(Text(section.rawValue).font(Font.hq(.subheadline).weight(.semibold))) \(number)")
                    .foregroundStyle(Color(uiColor: TodoInk.ready))
            } else {
                JobsHeaderWords(title: section.rawValue, count: count)
            }
            Spacer(minLength: 8)
            if section == .done, open, let toggle {
                Button(action: toggle) {
                    Text("Hide").padding(.top, 18).padding(.bottom, 6).contentShape(Rectangle())
                }
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqTint)
                .padding(.top, -18).padding(.bottom, -6)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.top, 20)
        .padding(.bottom, section == .stale ? 2 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Show N Done ⌄", the folded Done section's only row.
struct ShowDoneRowView: View {
    var count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text("Show \(count) Done").font(Font.hq(.callout))
            Image(systemName: "chevron.down").font(Font.hq(.footnote).weight(.semibold))
            Spacer()
        }
        .foregroundStyle(Color.hqTint)
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show \(count) Done")
        .accessibilityAddTraits(.isButton)
    }
}

/// Group By › My Sections: one of your sections' headers. Tap folds it; ⋯ holds Add Task, Rename, Move Up/Down and
/// Delete. "No Section" (`menu` nil) only folds.
struct TodoUserSectionHeaderView: View {
    struct Menu {
        var add: () -> Void
        var rename: () -> Void
        var moveUp: (() -> Void)?
        var moveDown: (() -> Void)?
        var delete: () -> Void
    }

    var name: String
    var count: Int
    var folded: Bool
    var toggle: () -> Void
    var menu: Menu?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(Font.hq(.caption).weight(.bold))
                        .foregroundStyle(Color.hqLabel3)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 12)
                    JobsHeaderWords(title: name, count: count)
                    Spacer(minLength: 8)
                }
                .padding(.top, 20).padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(count)")
            .accessibilityValue(folded ? "Folded" : "Open")
            .accessibilityHint(folded ? "Shows its tasks" : "Hides its tasks")
            .accessibilityAddTraits(.isHeader)
            if let menu {
                SwiftUI.Menu {
                    Button { menu.add() } label: { Label("Add Task", systemImage: "plus") }
                    Button { menu.rename() } label: { Label("Rename…", systemImage: "pencil") }
                    if let up = menu.moveUp { Button { up() } label: { Label("Move Up", systemImage: "arrow.up") } }
                    if let down = menu.moveDown { Button { down() } label: { Label("Move Down", systemImage: "arrow.down") } }
                    Divider()
                    Button(role: .destructive) { menu.delete() } label: { Label("Delete Section…", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle().inset(by: -8))   // a 44 pt target (audit 10-18)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.top, 14)
                .accessibilityLabel("\(name) Options")
                .accessibilityIdentifier("tasks.section-menu.\(name)")
            }
        }
        .animation(HQMotion.reduced ? nil : .snappy(duration: 0.2), value: folded)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty section's one row: where a dragged task can land, and how to get one there.
struct TodoEmptySectionRow: View {
    /// [mac] Mac polish #138: a task's menu is a Control-click on the Mac, not a hold.
    static func words(mac: Bool) -> String {
        "Drag tasks here, or \(mac ? DeviceWord.hold : "hold") a task and choose Move To."
    }

    var body: some View {
        Text(Self.words(mac: DeviceWord.isMac))
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel3)
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

/// "+ New Section", under your sections.
struct TodoNewSectionRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.rectangle").font(Font.hq(.callout))
            Text("New Section").font(Font.hq(.callout))
            Spacer()
        }
        .foregroundStyle(Color.hqTint)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
