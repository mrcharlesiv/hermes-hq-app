// [tasks-widget] The Tasks widget (docs/tasks.md item 12): the Tasks page's first screen on the Home Screen, in the
// page's own order and words, and counts alone on the Lock Screen (rule 6: task text never goes there). The app words
// every row (App/Widgets/TasksWidgetWriter.swift) into Keychain (HomeWidgetsKit/TasksWidgetStore.swift); this extension
// only reads it and never reaches the gateway. Each view carries its frames for the next two days (midnight, a due
// time), which are this widget's timeline.
//
// Taps: a row opens its task's sheet, the top line or anywhere else opens Tasks, "+" opens New Task. The check circle
// is a `TaskCheckOffIntent`, which iOS runs in the app.

import AppIntents
import OSLog
import SwiftUI
import WidgetKit

nonisolated struct TasksWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    var state: TasksWidgetIndex.State
    var scheme: String = ""
    var account: String = ""
    var view: String = "Today"
    var frame: TasksWidgetFrame?
    /// The theme's tint, light and dark (the Tile index carries it).
    var tint: Int? = nil
    var tintDark: Int? = nil
    /// The gallery's made-up list.
    var sample = false

    func link(_ link: WidgetLink) -> URL? { scheme.isEmpty ? nil : link.url(scheme: scheme) }
}

nonisolated struct TasksWidgetProvider: AppIntentTimelineProvider {
    static let log = Logger(subsystem: "ai.hermes.hq.widgets", category: "tasks")

    func placeholder(in context: Context) -> TasksWidgetEntry { TasksSample.entry() }

    func snapshot(for configuration: TasksWidgetIntent, in context: Context) async -> TasksWidgetEntry {
        let entries = Self.entries(configuration.view?.id, now: Date())
        // The gallery's preview: the real list when there is one, else a made-up one, never a quiet state.
        if context.isPreview, entries.first?.state != .live { return TasksSample.entry() }
        return entries.first ?? TasksSample.entry()
    }

    func timeline(for configuration: TasksWidgetIntent, in context: Context) async -> Timeline<TasksWidgetEntry> {
        let entries = Self.entries(configuration.view?.id, now: Date())
        // Counts only, never a task's words (docs/tasks.md rule 6): what a reload read, for the report's check-off proof.
        let first = entries.first?.frame
        Self.log.info("tasks timeline \(String(describing: context.family), privacy: .public): \(entries.count, privacy: .public) entries, \(first?.rowCount ?? -1, privacy: .public) rows, \(first?.sections.flatMap(\.rows).filter(\.done).count ?? 0, privacy: .public) ticked")
        // Past the last frame (two days on), the app's next write or the system's next ask brings more.
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// One entry a frame of the chosen view (Today when none is chosen, or the chosen list was deleted, as the page
    /// goes back to Today), the first from now.
    static func entries(_ chosen: String?, now: Date) -> [TasksWidgetEntry] {
        let tiles = TileWidgetStore.loadIndex()
        guard let index = TasksWidgetStore.loadIndex() else {
            return [TasksWidgetEntry(date: now, state: .signedOut, tint: tiles?.tint, tintDark: tiles?.tintDark)]
        }
        let base = TasksWidgetEntry(date: now, state: index.state, scheme: index.scheme, account: index.account,
                                    tint: tiles?.tint, tintDark: tiles?.tintDark)
        guard index.state == .live else { return [base] }
        let key = chosen.flatMap { id in index.views.contains { $0.id == id } ? id : nil } ?? TasksWidgetIndex.defaultView
        guard let view = TasksWidgetStore.loadView(key) ?? TasksWidgetStore.loadView(TasksWidgetIndex.defaultView),
              let first = view.frame(at: now) else {
            var entry = base
            entry.state = .noList
            return [entry]
        }
        var out: [TasksWidgetEntry] = []
        for frame in [first] + view.frames.filter({ $0.at > now }) {
            var entry = base
            entry = TasksWidgetEntry(date: max(frame.at, now), state: .live, scheme: base.scheme, account: base.account,
                                     view: view.name, frame: frame, tint: base.tint, tintDark: base.tintDark)
            out.append(entry)
        }
        return out
    }
}

struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HQWidgetKinds.tasks, intent: TasksWidgetIntent.self, provider: TasksWidgetProvider()) { entry in
            TasksWidgetContent(entry: entry)
        }
        .configurationDisplayName("Tasks")
        .description("Your Tasks from Hermes HQ: what's due, and what your bots have ready for you.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

struct TasksWidgetContent: View {
    let entry: TasksWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var tint: Color {
        (scheme == .dark ? entry.tintDark ?? entry.tint : entry.tint).map(Color.init(hex:)) ?? .accentColor
    }

    var body: some View {
        content
            .widgetURL(entry.link(entry.state == .live ? .tasks : .open))
            .containerBackground(for: .widget) {
                if family.isAccessory { AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0) }
                else { Color(uiColor: .systemBackground) }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            TasksLockView(words: TasksWidgetLock.words(entry.frame, view: entry.view, state: entry.state))
        default:
            if entry.state == .live, let frame = entry.frame {
                if family == .systemSmall {
                    TasksSmallView(entry: entry, frame: frame, tint: tint)
                } else {
                    TasksListView(entry: entry, frame: frame, family: TasksFamily(family), tint: tint)
                }
            } else {
                quiet
            }
        }
    }

    @ViewBuilder private var quiet: some View {
        switch entry.state {
        case .off:
            TileQuietView(symbol: "checklist", title: "Tasks Is Off", line: "Turn it on in Hermes HQ's Settings", tint: tint)
        case .needsAddOn:
            TileQuietView(symbol: "puzzlepiece.extension", title: "Update the Add-on", line: "Tasks needs a newer add-on on your computer", tint: tint)
        case .noList:
            TileQuietView(symbol: "checklist", title: "Tasks", line: "Open Hermes HQ to see your list", tint: tint)
        case .signedOut, .live:
            TileQuietView(symbol: nil, title: "Open Hermes HQ", line: nil, tint: tint)
        }
    }
}

extension TasksFamily {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemExtraLarge: self = .extraLarge
        default: self = .large
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool { self == .accessoryCircular || self == .accessoryRectangular || self == .accessoryInline }
}

/// The page's tone colours (`TodoInk`) and circle colours (`TodoPriorityLook`), as the app draws them.
nonisolated enum TasksInk {
    /// [theme review] Words in orange and red: deeper shades in light (the system's read at about 2.2 and 3.6:1 on a
    /// light widget; #B85400 and #D70015 hold 4.5:1), the system's own in dark.
    static let orange = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemOrange.resolvedColor(with: $0) : UIColor(red: 0.72, green: 0.33, blue: 0, alpha: 1) })
    static let red = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemRed.resolvedColor(with: $0) : UIColor(red: 0.84, green: 0, blue: 0.08, alpha: 1) })

    static func tone(_ raw: String, tint: Color) -> Color {
        switch raw {
        case "ready": return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
                                                                                       : UIColor(red: 0.11, green: 0.50, blue: 0.22, alpha: 1) })
        case "working": return tint
        case "needsYou": return orange
        case "overdue": return red
        default: return .secondary
        }
    }

    static func circle(_ priority: Int, tint: Color) -> Color {
        switch priority {
        case 1: return red
        case 2: return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1)
                                                                                 : UIColor(red: 0.93, green: 0.58, blue: 0, alpha: 1) })
        case 3: return tint
        default: return Color(uiColor: .tertiaryLabel)
        }
    }

    static func list(_ raw: String?) -> Color? {
        switch raw {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "yellow": .yellow
        case "gray": .gray
        default: nil
        }
    }
}

/// Small: the count that matters, then the top three tasks' names. One tap opens Tasks.
struct TasksSmallView: View {
    let entry: TasksWidgetEntry
    let frame: TasksWidgetFrame
    let tint: Color

    var body: some View {
        let head = TasksWidgetLayout.headline(frame, view: entry.view)
        let picked = TasksWidgetLayout.pick(frame, lines: TasksWidgetLayout.lines(.small), headings: false, notes: false)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(head.number)")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(head.waiting ? TasksInk.orange : tint)
                    .widgetAccentable()
                    .contentTransition(.numericText())
                Text(frame.count == 0 && !head.waiting ? "All Done" : head.words)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if picked.sections.isEmpty {
                Spacer(minLength: 0)
                Text(frame.empty).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                ForEach(picked.sections.flatMap(\.rows)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(row.done ? tint : TasksInk.circle(row.priority, tint: tint))
                            .accessibilityHidden(true)
                        Text(row.title)
                            .font(.footnote)
                            .strikethrough(row.done)
                            .foregroundStyle(row.done ? .secondary : .primary)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                }
                if picked.hidden > 0 {
                    Text(TasksWidgetLayout.moreLine(picked.hidden)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium and larger: the view's name and count with "+", then as many rows as fit, each with its circle.
struct TasksListView: View {
    let entry: TasksWidgetEntry
    let frame: TasksWidgetFrame
    let family: TasksFamily
    let tint: Color

    var body: some View {
        let picked = TasksWidgetLayout.pick(frame, lines: TasksWidgetLayout.lines(family), headings: TasksWidgetLayout.headings(family),
                                            notes: TasksWidgetLayout.notes(family))
        VStack(alignment: .leading, spacing: 4) {
            top
            if picked.sections.isEmpty {
                empty
            } else {
                ForEach(Array(picked.sections.enumerated()), id: \.offset) { index, section in
                    if let title = section.title {
                        HStack(spacing: 4) {
                            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(section.red ? TasksInk.red : Color.secondary)
                            if let detail = section.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                            // The group's count, as the page's heading has it ("Today 6"), shown rows or not.
                            if index < frame.sections.count {
                                Text("\(frame.sections[index].rows.count + frame.sections[index].more)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                    ForEach(section.rows) { row in TasksRowView(row: row, entry: entry, tint: tint) }
                }
                if picked.hidden > 0 {
                    Text(TasksWidgetLayout.moreLine(picked.hidden)).font(.footnote).foregroundStyle(.secondary).padding(.leading, 28)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var top: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Link(destination: entry.link(.tasks) ?? URL(string: "about:blank")!) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.view).font(.headline)
                    Text("\(frame.count)").font(.headline).foregroundStyle(.secondary).contentTransition(.numericText())
                    if frame.waiting > 0 {
                        Text("· \(frame.waiting) Waiting on You").font(.footnote.weight(.medium)).foregroundStyle(TasksInk.orange).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let new = entry.link(.newTask) {
                Link(destination: new) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(tint)
                        .widgetAccentable()
                        .accessibilityLabel("New Task")
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(tint).widgetAccentable().accessibilityHidden(true)
            Text("All Done").font(.headline)
            Text(frame.empty).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One task's row as the page draws it: the circle (a button that ticks it, in the app), the name with its marks, the
/// bot's line in its tone, the date at the end.
struct TasksRowView: View {
    let row: TasksWidgetRow
    let entry: TasksWidgetEntry
    let tint: Color
    @Environment(\.widgetFamily) private var family

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(intent: TaskCheckOffIntent(task: row.id, account: entry.account)) {
                Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: row.priority > 0 && !row.done ? .regular : .light))
                    .foregroundStyle(row.done ? tint : TasksInk.circle(row.priority, tint: tint))
                    .frame(width: 20, height: 20)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(row.done || entry.sample)
            .accessibilityLabel(row.done ? "Done" : "Mark Done")
            Link(destination: entry.link(.task(id: row.id, account: entry.account)) ?? URL(string: "about:blank")!) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        title
                            .lineLimit(1)
                            .privacySensitive()
                        if let note = row.note, family != .systemSmall {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(TasksInk.tone(row.tone, tint: tint))
                                .lineLimit(1)
                                .privacySensitive()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let goalColor = TasksInk.list(row.goalColor) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(row.done ? Color.gray : goalColor)
                            .accessibilityHidden(true)
                    }
                    if let when = row.when {
                        Text(when)
                            .font(.footnote).monospacedDigit()
                            .foregroundStyle(row.late && !row.done ? TasksInk.red : Color.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(minHeight: 22)
    }

    /// The name, then small and grey: steps done of all, and the repeat mark (as the page's `titleLine`).
    private var title: Text {
        var line = Text(row.title)
            .font(.callout)
            .foregroundStyle(row.done ? Color.secondary : Color.primary)
            .strikethrough(row.done)
        if let steps = row.steps {
            line = Text("\(line)\u{00A0}\u{00A0}\(Text(Image(systemName: "checklist")).font(.caption).foregroundStyle(.secondary))\u{00A0}\(Text(steps).font(.caption).monospacedDigit().foregroundStyle(.secondary))")
        }
        if row.repeats {
            line = Text("\(line)\u{00A0}\u{00A0}\(Text(Image(systemName: "repeat")).font(.caption).foregroundStyle(.tertiary))")
        }
        return line
    }
}

/// The Lock Screen: counts and the view's name, never a task's words.
struct TasksLockView: View {
    let words: TasksWidgetLock.Words
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(words.number).font(.system(.title2, design: .rounded).weight(.semibold)).minimumScaleFactor(0.6)
                Text(words.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
            }
            .widgetAccentable()
        case .accessoryInline:
            Label(words.inline, systemImage: "checklist")
        default:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(words.lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .headline : .body)
                        .widgetAccentable(index == 0)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The gallery's preview before the app has written a list: made-up tasks in the page's manner.
nonisolated enum TasksSample {
    static func entry() -> TasksWidgetEntry {
        let rows = [
            TasksWidgetRow(id: "s1", title: "Renew the parking permit", when: "Yesterday", late: true, priority: 1, tone: "plain"),
            TasksWidgetRow(id: "s2", title: "Pick up the dry cleaning", when: "5:00 PM", tone: "plain"),
            TasksWidgetRow(id: "s3", title: "Plan the team offsite", steps: "1/3", note: "Otto finished its part", tone: "ready"),
            TasksWidgetRow(id: "s4", title: "Water the plants", repeats: true, tone: "plain"),
        ]
        let frame = TasksWidgetFrame(at: Date(), count: 4, waiting: 1, sections: [
            TasksWidgetSection(title: "Overdue", red: true, rows: [rows[0]]),
            TasksWidgetSection(title: "Today", rows: [rows[1], rows[3]]),
            TasksWidgetSection(title: "Waiting on You", rows: [rows[2]]),
        ], empty: "Nothing due today.")
        return TasksWidgetEntry(date: Date(), state: .live, view: "Today", frame: frame, sample: true)
    }
}
