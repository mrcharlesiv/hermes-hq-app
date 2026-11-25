// [tasks-first] The Tasks page's rows (owner 2026-11-12, mockup 1-list-today: "One line per task"): a circle to tick,
// the name, a tiny 2/4 with steps, and when it's due at the end. [tasks-calm] A bot on the task has a quiet grey second
// line led by its small face, in its words (owner 2026-11-19 pick A, "Quiet ink": the face and its coloured dot at the
// row's end, and a green or orange line naming the bot, read busy); only a question keeps its orange. The Mac's table (a
// window-wide list) keeps its columns. [tasks-colour] Colour means act (owner 2026-11-22, pick A of
// artifacts/tasks-colour: ten hues said five things): on the list only a late date is red and only a bot's question
// is orange. Priority is "!!" or "!" before the name, a list is its small grey icon, a goal's mark and the bot's
// small face are grey.

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

    /// [tasks-colour] On the list (the Mac's table too): only what asks for you keeps a colour.
    static func onList(_ tone: TodoTone) -> Color {
        switch tone {
        case .needsYou: return Color.hqOrange
        case .overdue: return Color.hqRed
        case .ready, .working, .plain: return Color.hqLabel2
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
    /// [task-lists] Its list's icon, outside the list's own view: small and grey before the date ([tasks-colour] it
    /// was a dot in the list's colour).
    var listIcon: String?
    /// That list's name, for VoiceOver.
    var listName: String?
    /// [goals] Step 2: the task's goal (active or paused): its mark stands in the list's icon's place, everywhere but
    /// the goal's own page (`GoalViews.markGoal`).
    var goalMark = false
    /// That goal's name, for VoiceOver ("for <goal>").
    var goalName: String?
}

extension TodoRowModel {
    /// A task's row as the list draws it ([goals] the goal's page draws its tasks with the same rows).
    static func make(_ task: TodoTask, kind: TodoGroupKind, now: Date, botName: @escaping (String?) -> String, head: JSONValue?,
                     ticking: Bool = false, listIcon: String? = nil, listName: String? = nil, wide: Bool = false) -> TodoRowModel {
        TodoRowModel(
            id: task.id, title: task.title.isEmpty ? "Untitled Task" : task.title,
            words: TodoViews.row(task, in: kind, now: now, botName: botName),
            line: wide ? TodoWords.rowLine(task, section: TodoSections.section(task, now: now), now: now, botName: botName)
                       : TodoRowLine(lead: nil, tone: .plain, rest: []),
            done: task.isDone, ticking: ticking,
            face: task.helper, head: head,
            wide: wide, who: TodoWords.whoWords(task, botName: botName),
            listIcon: listIcon, listName: listName)
    }
}

struct TodoRowView: View {
    var row: TodoRowModel
    var toggle: () -> Void
    /// Pressed through accessibility: opens the task as a click does (`UICollectionView.pressRow`).
    var open: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var textLineFaceSize: CGFloat = 15
    /// [ui-sizing] × UI Scale too: a ScaledMetric follows only the text size, and at 150 % the text grew around it.
    private var lineFaceSize: CGFloat { HQFont.scaled(textLineFaceSize) }
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
            named
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.goalMark { goalMark(font: .subheadline) } else if let icon = row.listIcon { listMark(icon, font: .subheadline) }
            Text(row.line.lead ?? "")
                .font(Font.hq(.subheadline).weight(DeviceWord.isMac ? .regular : .medium)).foregroundStyle(TodoInk.onList(row.line.tone))   // [type] Mac: its colour marks it, as Jobs' status
                .lineLimit(1)
                .frame(width: TodoTable.status, alignment: .leading)
            Text(row.line.rest.joined(separator: " · "))
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                // Up to its width, and no more than the name's share: at the table's narrowest the name keeps half.
                .frame(minWidth: 0, maxWidth: TodoTable.details, alignment: .leading)
            HStack(spacing: 7) {
                if let profile = row.face {
                    HeadImage(raw: row.head, profile: profile, size: 18).frame(width: 18, height: 18)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.subheadline).capHeight / 2 }
                } else {
                    // [Mac AAA 2026-11-16] The face's room kept: "You" starts where "You & Hermes" does, as a column's
                    // words do (it stood 25 pt left of them).
                    Color.clear.frame(width: 18, height: 1)
                }
                Text(row.who).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            .frame(width: TodoTable.who, alignment: .leading)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, ListGutter.side)
        .frame(minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.line.text), \(row.who)\(row.listName.map { ", in \($0)" } ?? "")\(row.goalName.map { ", for \($0)" } ?? "")")
        .accessibilityValue(row.done ? "Done" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }   // [lists] Mac pass round 6
        .accessibilityAction(named: row.done ? "Mark Not Done" : "Mark Done") { toggle() }
    }

    /// [tasks-calm] Quiet ink (owner 2026-11-19, pick A of hermes-hq/workspace/mockups/tasks-calm: the page read busy):
    /// the row's end holds only when it is due (or its steps, with no date). The bot's line is grey, led by its small
    /// face instead of its name; only a question keeps its colour. No dot on the face: the line says what it is doing.
    /// Steps of a dated task with a bot's line end that line ("Draft ready · 1/2").
    /// [mac-tasks-calm] Owner 2026-11-22 (a Mac screenshot of Today: "this feels SO busy on Mac"): on the Mac a row is
    /// the task alone. The bot's line stays only for a question (it asks for you); otherwise the bot's small grey face
    /// sits before the date and its words show under the pointer, and on the task's page beside the list. VoiceOver
    /// still hears them (`spoken`). The name still wraps to two lines: cut to one in the narrow column it read
    /// "Reply to Ivy ab…".
    private var oneLine: Bool { DeviceWord.isMac && !large }

    private var list: some View {
        let words = row.done ? nil : (row.words.said ?? row.words.note)
        let said = oneLine && row.words.tone != .needsYou ? nil : words
        let faceAtEnd: String? = oneLine && said == nil && words != nil ? row.face : nil
        let pointerWords: String = faceAtEnd == nil ? "" : (words ?? "")
        let stepsAtEnd = row.words.when == nil && row.words.steps != nil
        let stepsOnLine = !stepsAtEnd && said != nil && row.words.steps != nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 2) {
                // At the largest sizes the date goes under the name, so the name keeps the row's width.
                let top = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                top {
                    // The marks run on after the name's last word, so a long name wraps to a second line with them
                    // (cut to one line it read "Reply to Ivy about the ve…").
                    titleLine(steps: !stepsAtEnd && !stepsOnLine)
                        .lineLimit(large ? 4 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // [task-lists] Its list's icon, before the date (and alone at the row's end with no date); [goals] its
                    // goal's mark in that place instead. Neither at the largest sizes (the spoken words stay).
                    if !large {
                        if row.goalMark { goalMark(font: .footnote) } else if let icon = row.listIcon { listMark(icon, font: .footnote) }
                    }
                    if let profile = faceAtEnd { lineFace(profile) }
                    if let when = row.words.when {
                        Text(when)
                            .font(Font.hq(.footnote)).monospacedDigit()
                            .foregroundStyle(row.words.late && !row.done ? Color.hqRed : Color.hqLabel2)
                            .lineLimit(1)
                            .fixedSize()
                    } else if stepsAtEnd, let steps = row.words.steps {
                        stepsText(steps, font: Font.hq(.footnote))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let said {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if let profile = row.face { lineFace(profile) }
                        Text(said)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(row.words.tone == .needsYou ? Color.hqOrange : Color.hqLabel2)
                            .lineLimit(large ? nil : 1)
                            .layoutPriority(stepsOnLine ? 0 : 1)
                        // The steps stay whole; a long line is cut before them, not them.
                        if stepsOnLine, let steps = row.words.steps {
                            Text("\(Text("·").foregroundStyle(Color.hqLabel3))\u{00A0}\(stepsText(steps, font: Font.hq(.footnote)))")
                                .font(Font.hq(.footnote))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, Theme.isDesktop ? 10 : 8)
        .padding(.leading, ListGutter.side)
        .padding(.trailing, ListGutter.side)
        .frame(minHeight: Theme.isDesktop ? 46 : 44, alignment: .leading)
        .contentShape(Rectangle())
        .help(pointerWords)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(listSpoken)
        .accessibilityValue(row.done ? "Done" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }   // [lists] Mac pass round 6
        .accessibilityAction(named: row.done ? "Mark Not Done" : "Mark Done") { toggle() }
    }

    /// The list row's words for VoiceOver: the name, then what is drawn beside and under it.
    private var listSpoken: String {
        var parts = [row.title]
        if !row.words.spoken.isEmpty { parts.append(row.words.spoken) }
        if let list = row.listName { parts.append("in \(list)") }
        if let goal = row.goalName { parts.append("for \(goal)") }
        return parts.joined(separator: ", ")
    }

    /// The name, then small and grey: steps done of all, and a mark for a task that repeats. (A mark for notes was
    /// tried and dropped: it pushed long names onto a second line and said little.) The marks are
    /// tied to the name's last word (no-break spaces), so a long name wraps with them: a count never sits on a line
    /// alone.
    private func titleLine(steps showsSteps: Bool) -> Text {
        var line = named
        let small = Font.hq(.caption)
        let gap = "\u{00A0}\u{00A0}"
        if showsSteps, let steps = row.words.steps {
            line = Text("\(line)\(gap)\(stepsText(steps, font: small))")
        }
        if row.words.repeats {
            line = Text("\(line)\(gap)\(Text(Image(systemName: "repeat")).font(small).foregroundStyle(Color.hqLabel3))")
        }
        // Its tags (a list and Inbox, where the row has the room), each "#word", tied on like the marks.
        for tag in row.words.tags {
            let word = "#" + tag.replacingOccurrences(of: " ", with: "\u{00A0}")
            line = Text("\(line)\(gap)\(Text(word).font(small).foregroundStyle(Color.hqLabel2))")
        }
        return line
    }

    /// [tasks-colour] The name, after its priority's mark while it is open: "!!" (high) in the name's ink and weight
    /// made heavy, "!" (medium) in grey. The circle is plain: its colour said the same and read as a third red.
    private var named: Text {
        let struck = row.done || row.ticking
        let name = Text(row.title)
            .font(Font.hq(.callout))
            .foregroundStyle(struck ? Color.hqLabel2 : Color.hqLabel)
            .strikethrough(struck, color: Color.hqLabel3)
        guard !struck, let mark = TodoViews.priorityMark(row.words.priority) else { return name }
        let ink = row.words.priority == 1 ? Color.hqLabel : Color.hqLabel2
        return Text("\(Text(mark).font(Font.hq(.callout).weight(.bold)).foregroundStyle(ink))\u{00A0}\(name)")
    }

    /// [task-lists] The list's icon, small and grey, centred on the words' x-height beside it.
    private func listMark(_ icon: String, font: UIFont.TextStyle) -> some View {
        Image(systemName: icon)
            .font(Font.hq(.caption2).weight(.medium))
            .foregroundStyle(row.done ? Color.hqLabel3 : Color.hqLabel2)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(font).xHeight / 2 }
            .accessibilityHidden(true)
            .accessibilityIdentifier("tasks.list-mark")
    }

    /// [goals] The goal's mark, grey, centred on the words' x-height beside it, as the list's icon is.
    private func goalMark(font: UIFont.TextStyle) -> some View {
        Image(systemName: "smallcircle.filled.circle")
            .font(Font.hq(.caption2).weight(.semibold))
            .foregroundStyle(row.done ? Color.hqLabel3 : Color.hqLabel2)
            .accessibilityHidden(true)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(font).xHeight / 2 }
            .accessibilityIdentifier("tasks.goal-mark")
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
                // [tasks-colour] Plain for every open task: its priority is the mark before its name (`named`).
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

    /// Steps done of all, small and grey: "☰ 2/4".
    private func stepsText(_ steps: String, font: Font) -> Text {
        Text("\(Text(Image(systemName: "checklist")))\u{00A0}\(Text(steps).monospacedDigit())").font(font).foregroundStyle(Color.hqLabel2)
    }

    /// [tasks-calm] The bot's face, small, at the head of its line (the line's words say what it is doing).
    /// [tasks-colour] In grey: its shape still says which bot, and its colour was one more hue on every line.
    private func lineFace(_ profile: String) -> some View {
        let size = min(22, lineFaceSize).rounded()
        return HeadImage(raw: row.head, profile: profile, size: size)
            .frame(width: size, height: size)
            .grayscale(1)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.footnote).capHeight / 2 }
            .accessibilityHidden(true)
    }
}

/// A group's heading: "Overdue 1" ([tasks-colour] in ink: its rows' dates are the red), "Today 5", "Tomorrow  Fri, Nov 13", a bot's face and name in Bots, and Done
/// with Show or Hide at its end.
struct TodoGroupHeaderView: View {
    var title: String
    var detail: String?
    var count: Int?
    /// [soft-cards] The group stands on a soft card: the name starts where the rows' circles do, and as far under the
    /// card's top as the last row's words stand over its foot.
    var onCard = false
    /// Bots: the bot whose tasks follow.
    var face: (profile: String, head: JSONValue?)?
    /// "Still Need These?": why they're here.
    var note: String?
    /// Done: "Show" or "Hide", and what it does.
    var fold: (title: String, action: () -> Void)?
    /// [goals] The fold's identifier (Achieved and Let Go fold too).
    var foldID = "tasks.show-done"
    /// Overdue: 1-tap bulk Reschedule menu (Today, Tomorrow, Next Week, Choose Date…).
    var reschedule: (today: () -> Void, tomorrow: () -> Void, nextWeek: () -> Void, pick: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let face {
                    HeadImage(raw: face.head, profile: face.profile, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                }
                words
                Spacer(minLength: 8)
                if let reschedule {
                    Menu {
                        Button("Today", systemImage: "sun.max", action: reschedule.today)
                        Button("Tomorrow", systemImage: "sunrise", action: reschedule.tomorrow)
                        Button("Next Week", systemImage: "calendar", action: reschedule.nextWeek)
                        Button("Choose Date…", systemImage: "calendar.badge.plus", action: reschedule.pick)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Reschedule")
                            Image(systemName: "chevron.down").font(Font.hq(.caption2).weight(.semibold)).accessibilityHidden(true)
                        }
                        .padding(.top, 16).padding(.bottom, 6).padding(.leading, 12)
                        .contentShape(Rectangle())
                    }
                    .font(Font.hq(.subheadline).weight(.medium))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .padding(.top, -16).padding(.bottom, -6)
                    .accessibilityLabel("Reschedule Overdue Tasks")
                    .accessibilityIdentifier("tasks.overdue.reschedule")
                }
                if let fold {
                    Button(action: fold.action) {
                        Text(fold.title).padding(.top, 16).padding(.bottom, 6).padding(.leading, 12).contentShape(Rectangle())
                    }
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .padding(.top, -16).padding(.bottom, -6)
                    .accessibilityIdentifier(foldID)
                }
            }
            .padding(.horizontal, onCard ? ListGutter.side + BackdropCards.side : ListGutter.side)
            .padding(.top, onCard ? 13 : 16)
            .padding(.bottom, note == nil ? 4 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, onCard ? ListGutter.side + BackdropCards.side : ListGutter.side)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tasks.stale.note")
            }
        }
    }

    private var words: some View { Words(title: title, detail: detail, count: count) }

    /// "Today  5": the name in the label's ink, what follows in grey (the Desktop Look's small capitals there).
    struct Words: View {
        var title: String
        var detail: String?
        var count: Int?
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            if Theme.isDesktop {
                Text(([title] + [detail].compactMap { $0 } + [count.map { "\($0)" }].compactMap { $0 }).joined(separator: " · "))
                    .monospacedDigit()
                    .hqDesktopLabel(color: .hqLabel2)
            } else {
                let name = Text(title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                let rest = [detail, count.map { "\($0)" }].compactMap { $0 }.joined(separator: "  ")
                if rest.isEmpty {
                    name
                } else {
                    Text("\(name)  \(Text(rest).font(Font.hq(.subheadline)).monospacedDigit().foregroundStyle(Color.hqHeadCount(contrast)))")
                }
            }
        }
    }
}

/// Upcoming's week: seven days at a time, swipeable or stepped week-by-week, with a dot under days that have tasks.
/// A tap on a day shows that day alone; dropping a task onto a day reschedules it there.
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

    var title: String = ""
    var showTodayButton = false
    var days: [Day]
    var pick: (String) -> Void
    var stepWeek: (Int) -> Void = { _ in }
    var goToday: () -> Void = {}
    var onDropTask: (String, String) -> Bool = { _, _ in false }
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 4) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                        .accessibilityIdentifier("tasks.week.month")
                    Spacer(minLength: 8)
                    if showTodayButton {
                        Button(action: goToday) {
                            Text("Today")
                                .font(Font.hq(.caption).weight(.semibold))
                                .foregroundStyle(Color.hqTintText)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(Color.hqTint.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Jump to This Week")
                        .accessibilityIdentifier("tasks.week.today")
                    }
                    HStack(spacing: 4) {
                        Button { stepWeek(-1) } label: {
                            Image(systemName: "chevron.left")
                                .font(Font.hq(.caption).weight(.semibold))
                                .foregroundStyle(Color.hqLabel2)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.hqFill3))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Previous Week")
                        .accessibilityIdentifier("tasks.week.prev")
                        Button { stepWeek(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(Font.hq(.caption).weight(.semibold))
                                .foregroundStyle(Color.hqLabel2)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.hqFill3))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Next Week")
                        .accessibilityIdentifier("tasks.week.next")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.key) { day in
                    let targeted = dropTarget == day.key
                    Button { pick(day.key) } label: {
                        VStack(spacing: 3) {
                            Text(day.weekday.uppercased())
                                .font(Font.hq(.caption2).weight(.semibold))
                                .foregroundStyle(targeted ? Color.hqTintText : Color.hqLabel2)
                            // The picked day is the filled circle; today, while it isn't picked, is the accent's number (as
                            // Calendar's week). With no day picked the list holds every coming day.
                            Text(day.number)
                                .font(Font.hq(.callout).weight(day.today || targeted || (day.picked && !DeviceWord.isMac) ? .semibold : .regular)).monospacedDigit()   // [type] Mac: the circle shows the pick
                                .foregroundStyle(day.picked ? Color.hqOnTint : (day.today || targeted ? Color.hqTintText : (day.busy ? Color.hqLabel : Color.hqLabel2)))
                                .frame(width: HQFont.scaled(32), height: HQFont.scaled(32))
                                .background {
                                    if day.picked {
                                        Circle().fill(Color.hqTint)
                                    } else if targeted {
                                        Circle().fill(Color.hqTint.opacity(0.18))
                                            .overlay { Circle().strokeBorder(Color.hqTint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                                    }
                                }
                            Circle().fill(day.busy ? Color.hqLabel3 : Color.clear).frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first else { return false }
                        let taskID = raw.hasPrefix("hq-task:") ? String(raw.dropFirst("hq-task:".count)) : raw
                        return onDropTask(taskID, day.key)
                    } isTargeted: { on in
                        if on {
                            if dropTarget != day.key { PagesHaptics.selection() }
                            dropTarget = day.key
                        } else if dropTarget == day.key {
                            dropTarget = nil
                        }
                    }
                    .accessibilityLabel("\(day.weekday) \(day.number)\(day.today ? ", today" : "")")
                    .accessibilityValue(day.busy ? "Has tasks" : "No tasks")
                    .accessibilityAddTraits(day.picked ? .isSelected : [])
                    .accessibilityHint(day.picked ? "Shows every coming day again" : "Shows this day alone")
                    .accessibilityIdentifier("tasks.week.\(day.key)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .gesture(DragGesture(minimumDistance: 36, coordinateSpace: .local).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                stepWeek(value.translation.width < 0 ? 1 : -1)
            })
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Dismissible chips shown only while a Priority or Tag filter is active, so nothing stays silently hidden.
struct TaskActiveFiltersBar: View {
    var priority: Int?
    var tag: String?
    var clearPriority: () -> Void
    var clearTag: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let priority {
                    chip("\(TodoViews.priorityWord(priority)) priority", symbol: "flag.fill",
                         id: "tasks.filter.active.priority", action: clearPriority)
                }
                if let tag {
                    chip("#\(tag)", symbol: "tag", id: "tasks.filter.active.tag", action: clearTag)
                }
            }
            .padding(.horizontal, ListGutter.side)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.filter.active")
    }

    private func chip(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(Font.hq(.caption2).weight(.semibold)).accessibilityHidden(true)
            }
            .font(Font.hq(.footnote).weight(.medium))
            .foregroundStyle(Color.hqTintText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.hqTint.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear filter \(title)")
        .accessibilityIdentifier(id)
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
