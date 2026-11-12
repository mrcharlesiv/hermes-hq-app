// [tasks-first] The Tasks page's rows (owner 2026-11-12, mockup 1-list-today: "One line per task"): a circle to tick,
// the name, a tiny 2/4 with steps, and when it's due at the end. A bot on the task is a small face after that, with a
// dot for what it is doing (blue working, green finished its part, orange has a question). A second line shows only
// when the bot has something for you, in its words. The Mac's table (a window-wide list) keeps its columns.

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
    /// [tasks-first] When, the steps, and the bot's line and dot.
    var words = TodoRowWords()
    /// [mac-tools] The Mac table's status and details columns.
    var line: TodoRowLine
    var done: Bool
    /// Ticked here and about to move to Done.
    var ticking = false
    /// The bot on the task (its own, or one you share): its face at the row's end.
    var face: String?
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
    @ScaledMetric(relativeTo: .callout) private var textFaceSize: CGFloat = 20
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
                if let profile = row.face {
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
            VStack(alignment: .leading, spacing: 2) {
                // At the largest sizes the date goes under the name, so the name keeps the row's width.
                let top = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                top {
                    // The marks run on after the name's last word, so a long name wraps to a second line with them
                    // (cut to one line it read "Reply to Ivy about the ve…").
                    titleLine
                        .lineLimit(large ? 4 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let when = row.words.when {
                        Text(when)
                            .font(Font.hq(.footnote)).monospacedDigit()
                            .foregroundStyle(row.words.late && !row.done ? Color.hqRed : Color.hqLabel2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let note = row.words.note {
                    Text(note)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(TodoInk.color(row.words.tone))
                        .lineLimit(large ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let profile = row.face { face(profile) }
        }
        .padding(.vertical, Theme.isDesktop ? 10 : 8)
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(minHeight: Theme.isDesktop ? 46 : 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.words.spoken.isEmpty ? row.title : "\(row.title), \(row.words.spoken)")
        .accessibilityValue(row.done ? "Done" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: row.done ? "Mark Not Done" : "Mark Done") { toggle() }
    }

    /// The name, then small and grey: steps done of all, and a mark for a task that repeats. (A mark for notes was
    /// tried and dropped: it pushed long names onto a second line and said little.) The marks are
    /// tied to the name's last word (no-break spaces), so a long name wraps with them: a count never sits on a line
    /// alone.
    private var titleLine: Text {
        let struck = row.done || row.ticking
        var line = Text(row.title)
            .font(Font.hq(.callout))
            .foregroundStyle(struck ? Color.hqLabel2 : Color.hqLabel)
            .strikethrough(struck, color: Color.hqLabel3)
        let small = Font.hq(.caption)
        let gap = "\u{00A0}\u{00A0}"
        if let steps = row.words.steps {
            line = Text("\(line)\(gap)\(Text(Image(systemName: "checklist")).font(small).foregroundStyle(Color.hqLabel2))\u{00A0}\(Text(steps).font(small).monospacedDigit().foregroundStyle(Color.hqLabel2))")
        }
        if row.words.repeats {
            line = Text("\(line)\(gap)\(Text(Image(systemName: "repeat")).font(small).foregroundStyle(Color.hqLabel3))")
        }
        return line
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

    /// The bot's face, with a dot at its foot for what it is doing.
    private func face(_ profile: String) -> some View {
        let size = min(30, faceSize).rounded()
        let dot = (size * 0.42).rounded()
        return HeadImage(raw: row.head, profile: profile, size: size)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let kind = row.words.dot, !row.done {
                    Circle().fill(TodoRowView.dotColor(kind))
                        .frame(width: dot, height: dot)
                        .overlay { Circle().strokeBorder(Color.hqPage, lineWidth: 1.5) }
                        .offset(x: dot * 0.3, y: dot * 0.3)
                }
            }
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.callout).capHeight / 2 }
            .accessibilityHidden(true)
    }

    static func dotColor(_ dot: TodoDot) -> Color {
        switch dot {
        case .working: return Color.hqTint
        case .ready: return Color(uiColor: TodoInk.ready)
        case .question: return Color.hqOrange
        }
    }
}

/// A group's heading: "Overdue 1" in red, "Today 5", "Tomorrow  Fri, Nov 13", a bot's face and name in Bots, and Done
/// with Show or Hide at its end.
struct TodoGroupHeaderView: View {
    var title: String
    var detail: String?
    var count: Int?
    var red = false
    /// Bots: the bot whose tasks follow.
    var face: (profile: String, head: JSONValue?)?
    /// "Still Need These?": why they're here.
    var note: String?
    /// Done: "Show" or "Hide", and what it does.
    var fold: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let face {
                    HeadImage(raw: face.head, profile: face.profile, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                }
                words
                Spacer(minLength: 8)
                if let fold {
                    Button(action: fold.action) {
                        Text(fold.title).padding(.top, 16).padding(.bottom, 6).padding(.leading, 12).contentShape(Rectangle())
                    }
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .padding(.top, -16).padding(.bottom, -6)
                    .accessibilityIdentifier("tasks.show-done")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, note == nil ? 4 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
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

    private var words: some View { Words(title: title, detail: detail, count: count, red: red) }

    /// "Today  5": the name in the label's ink, what follows in grey (the Desktop Look's small capitals there).
    struct Words: View {
        var title: String
        var detail: String?
        var count: Int?
        var red: Bool

        var body: some View {
            if Theme.isDesktop {
                Text(([title] + [detail].compactMap { $0 } + [count.map { "\($0)" }].compactMap { $0 }).joined(separator: " · "))
                    .monospacedDigit()
                    .hqDesktopLabel(color: red ? .hqRed : .hqLabel2)
            } else {
                let name = Text(title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(red ? Color.hqRed : Color.hqLabel)
                let rest = [detail, count.map { "\($0)" }].compactMap { $0 }.joined(separator: "  ")
                if rest.isEmpty {
                    name
                } else {
                    Text("\(name)  \(Text(rest).font(Font.hq(.subheadline)).monospacedDigit().foregroundStyle(Color.hqLabel2))")
                }
            }
        }
    }
}

/// Upcoming's week: the next seven days, a dot under a day with tasks. A tap on such a day goes to it.
struct TodoWeekStrip: View {
    struct Day: Hashable {
        var key: String
        var weekday: String
        var number: String
        var today: Bool
        var busy: Bool
        /// The day on show: the list holds this day alone. A second tap shows every day again.
        var picked = false
    }

    var days: [Day]
    var pick: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.key) { day in
                Button { pick(day.key) } label: {
                    VStack(spacing: 3) {
                        Text(day.weekday.uppercased())
                            .font(Font.hq(.caption2).weight(.semibold))
                            .foregroundStyle(Color.hqLabel2)
                        // The picked day is the filled circle; today, while it isn't picked, is the accent's number (as
                        // Calendar's week). With no day picked the list holds every coming day.
                        Text(day.number)
                            .font(Font.hq(.callout).weight(day.today || day.picked ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(day.picked ? Color.hqOnTint : (day.today ? Color.hqTintText : (day.busy ? Color.hqLabel : Color.hqLabel2)))
                            .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
                            .background { if day.picked { Circle().fill(Color.hqTint) } }
                        Circle().fill(day.busy ? Color.hqLabel3 : Color.clear).frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.weekday) \(day.number)\(day.today ? ", today" : "")")
                .accessibilityValue(day.busy ? "Has tasks" : "No tasks")
                .accessibilityAddTraits(day.picked ? .isSelected : [])
                .accessibilityHint(day.picked ? "Shows every coming day again" : "Shows this day alone")
                .accessibilityIdentifier("tasks.week.\(day.key)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// A view with nothing in it: one quiet line.
struct TodoViewEmptyRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Font.hq(.subheadline))
            .foregroundStyle(Color.hqLabel2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 16)
            .accessibilityIdentifier("tasks.view-empty")
    }
}
