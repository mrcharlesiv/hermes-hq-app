// [tasks-first] Owner 2026-11-12 ("every task is pure task management first, agent stuff second … THEN agent stuff
// built along side it so it feels more like you have a teammate in there"; mockups 3-task-your-own and
// 4-task-with-a-bot, "I love all of this"): the same view for every task. The title, then one line each for when it's
// due, how it repeats and who has it (step 3 adds its alert, start day, priority and tags, TaskFields.swift); notes;
// steps; files. A task of your own stops there: no bot's name, no message
// box. A bot on the task is named on the who row with what it is doing, its face is on its steps and files, and its
// conversation is the page's last section with a one-line message box under it. Only a question for you moves up,
// as one card under the who row with its answers as taps. "Assign" on the who row is the one way a bot comes in.
//
// [tasks] The task's view, organized the way the task apps organize a task (owner 2026-11-09: the plain page "doesn't
// feel well organized … like we just threw everything on there. Go look at how task management tools organize
// everything and let's just copy them", then "Yeah do that" to the recommendation; references and mockups in
// share/2026-11-09-task-organized/compare). From Todoist: one icon column and one text column from top to bottom, a
// band between sections, bold headings with a count, open steps first, then Add step, then the finished ones crossed
// out, and what the bot made attached to the message it came with. From TickTick: few rows (the top bar already names
// the bot, so there is no Who row; when the bot looks again is a quiet line under its message). Ours alone: the bot's
// latest message comes second, above the steps, because it is where the task stands and why you opened it; its
// answers are one button and plain words (option A).

import SwiftUI

struct TaskPlainView: View {
    @Bindable var model: TodoSheetModel
    let task: TodoTask
    @FocusState private var focus: Field?
    /// Long notes are open (More on the Notes heading); they start folded each time the page opens.
    @State private var notesOpen = false
    @State private var notesWidth: CGFloat = 0
    /// The lines long notes fold to.
    static let notesFold = 3
    enum Field: Hashable { case step, notes }
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The page has a bot's conversation (a bot is on the task, or it had one): its section, card and message box show.
    private var teammate: Bool { model.chatAtHand }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    completedRow
                    dueRow
                    startRow
                    repeatRow
                    priorityRow
                    tagsRow
                    whoRow
                    if model.gone {
                        TaskGridRow(last: true, topLine: true) { Image(systemName: "trash") } text: {
                            Text("This task was deleted.").foregroundStyle(Color.hqLabel2)
                        }
                    }
                    moreRow
                    if teammate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in TaskTeammate(model: model, task: task, part: .ask, tick: context.date) }
                    }
                    notes
                    steps(proxy)
                    files
                    // Beside its chat (the Mac's pane) the task needs no copy of the conversation at its foot.
                    if teammate, !model.split {
                        TimelineView(.periodic(from: .now, by: 1)) { context in TaskTeammate(model: model, task: task, part: .foot, tick: context.date) }
                    }
                }
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // What the page draws, said at once and on every change (the scroll view's own geometry said nothing
                // until something changed, so a page that drew right the first time kept its starting height).
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onLeadHeight?($0 + (showsMessageLine ? TaskMessageLine.height : 0)) }
            }
            // On a chat's page the view scrolls only once it is taller than its panel; standing alone it is the page.
            .scrollDisabled(model.embedded && !model.briefScrolls)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.editingNotes) { _, editing in
                if editing { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("task.notes", anchor: .bottom) } } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsMessageLine {
                TaskMessageLine(name: model.botName(model.chatBot(task)), draft: model.draft) { model.writeMessage() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focus != nil {
                    Spacer()
                    Button("Done") { PagesHaptics.selection(); focus = nil }
                        .font(Font.hq(.body).weight(.semibold))
                        .accessibilityIdentifier("task.edit-done")
                }
            }
        }
        .onChange(of: task.rev) { _, rev in model.taskChanged(rev) }
        // The bar's title is the task's list: a move (or a rename) shows there at once.
        .onChange(of: model.listTitle) { _, _ in model.onBriefLayoutChange?() }
    }

    /// The one-line message box: on a task with a bot's conversation, while no field of the view has the keys.
    private var showsMessageLine: Bool { model.embedded && !model.gone && !model.editingBrief }

    // MARK: Top

    /// The circle (finishes it, or opens it again) and the title, at the page's own scale.
    private var titleRow: some View {
        TaskGridRow(last: true, minHeight: 46) {
            Button { task.isDone ? model.reopen() : model.markDone() } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(.title2).weight(.light))
                    // An open task's circle is its priority's colour.
                    .foregroundStyle(task.isDone ? Color.hqTint : (TodoPriorityLook.color(task.priority) ?? Color.hqLabel3))
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .disabled(model.gone)
            .accessibilityLabel(task.isDone ? "Done. Open it again" : "Mark Done")
            .accessibilityIdentifier("task.check")
        } text: {
            Text(task.title.isEmpty ? "Untitled Task" : task.title)
                .font(Font.hqSystem(.title3, design: .default, weight: .semibold))
                .foregroundStyle(task.isDone ? Color.hqLabel2 : Color.hqLabel)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("task.title")
        }
    }

    /// A finished task says when: "Completed today, 11:40 AM". A tap shows its History.
    @ViewBuilder private var completedRow: some View {
        if task.isDone {
            Button { model.showHistory() } label: {
                TaskGridRow {
                    Image(systemName: "checkmark").foregroundStyle(Color.hqLabel2)
                } text: {
                    Text(TaskBarView.completed(task)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the task’s history")
            .accessibilityIdentifier("task.completed")
        }
    }

    /// When it's due: a menu. Red once it's late, orange on its day.
    private var dueRow: some View {
        let now = Date()
        let due = TodoDates.due(task.due)
        let color: Color = {
            guard let due, !task.isDone else { return Color.hqLabel }
            if due.hasTime ? due.date < now : Calendar.current.startOfDay(for: due.date) < Calendar.current.startOfDay(for: now) { return Color.hqRed }
            return Calendar.current.isDate(due.date, inSameDayAs: now) ? Color.hqOrange : Color.hqLabel
        }()
        let words = due == nil ? "No date" : TodoWords.dueTile(task, now: now)
        // Its alert, when it has one of its own and this phone rings for it (not a bot's own task).
        let rings = model.hasFields && due != nil && task.whoKind != .bot
        let alert = rings && !task.isDone ? task.alert.flatMap { $0 > 0 ? TodoReminder.alertWords($0) : nil } : nil
        return Menu {
            Button("Today") { model.setDue(now, hasTime: false) }
            Button("Tomorrow") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…") { pickDate() }
            if rings {
                Menu("Alert") {
                    Button { model.setAlert(nil) } label: {
                        if (task.alert ?? 0) == 0 { Label("At Its Time", systemImage: "checkmark") } else { Text("At Its Time") }
                    }
                    ForEach(TodoReminder.alerts.filter { $0 > 0 }, id: \.self) { minutes in
                        Button { model.setAlert(minutes) } label: {
                            if task.alert == minutes { Label(TodoReminder.alertWords(minutes), systemImage: "checkmark") } else { Text(TodoReminder.alertWords(minutes)) }
                        }
                    }
                }
            }
            if due != nil { Button("No Due Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            TaskGridRow {
                Image(systemName: "calendar").foregroundStyle(due == nil || color == Color.hqLabel ? Color.hqLabel2 : color)
            } text: {
                HStack(spacing: 8) {
                    Text(words).foregroundStyle(due == nil ? Color.hqLabel3 : color).lineLimit(1)
                    Spacer(minLength: 4)
                    if let alert {
                        HStack(spacing: 4) {
                            Image(systemName: "bell").imageScale(.small).accessibilityHidden(true)
                            Text(alert).lineLimit(1)
                        }
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("task.alert")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.gone)
        .accessibilityLabel("Due: \(words)\(alert.map { ", alert \($0)" } ?? ""). Change")
        .accessibilityIdentifier("task.due")
    }

    /// The day it starts, once it has one: until then it waits under Upcoming, from then on it is in Today.
    @ViewBuilder private var startRow: some View {
        if model.hasFields, let words = TodoViews.startWords(task, now: Date()) {
            Menu { startChoices } label: {
                TaskGridRow {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(Color.hqLabel2)
                } text: {
                    Text(words).foregroundStyle(Color.hqLabel).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.gone)
            .accessibilityLabel("\(words). Change")
            .accessibilityIdentifier("task.start")
        }
    }

    @ViewBuilder private var startChoices: some View {
        let now = Date()
        Button("Today") { model.setStart(now) }
        Button("Tomorrow") { model.setStart(Calendar.current.date(byAdding: .day, value: 1, to: now)) }
        Button("Next Week") { model.setStart(Calendar.current.date(byAdding: .day, value: 7, to: now)) }
        Button("Choose Date…") { model.pickStart() }
        if task.starts != nil { Button("No Start Date", role: .destructive) { model.setStart(nil) } }
    }

    /// Its priority, once it has one: a flag in the circle's colour.
    @ViewBuilder private var priorityRow: some View {
        if model.hasFields, task.priority > 0 {
            let words = "\(TodoViews.priorityWord(task.priority)) priority"
            Menu { priorityChoices } label: {
                TaskGridRow {
                    Image(systemName: "flag.fill").foregroundStyle(TodoPriorityLook.color(task.priority) ?? Color.hqLabel2)
                } text: {
                    Text(words).foregroundStyle(Color.hqLabel).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.gone)
            .accessibilityLabel("\(words). Change")
            .accessibilityIdentifier("task.priority")
        }
    }

    @ViewBuilder private var priorityChoices: some View {
        ForEach([1, 2, 3], id: \.self) { level in
            Button { model.setPriority(level) } label: {
                if task.priority == level { Label(TodoViews.priorityWord(level), systemImage: "checkmark") } else { Text(TodoViews.priorityWord(level)) }
            }
        }
        if task.priority > 0 { Button("No Priority", role: .destructive) { model.setPriority(0) } }
    }

    /// Its tags, once it has any. A tap changes them.
    @ViewBuilder private var tagsRow: some View {
        if model.hasFields, !task.tags.isEmpty {
            Button { model.editTags() } label: {
                TaskGridRow {
                    Image(systemName: "tag").foregroundStyle(Color.hqLabel2)
                } text: {
                    PagesFlowLayout(spacing: 6, lineSpacing: 4) {
                        ForEach(task.tags, id: \.self) { tag in TaskTagPill(tag: tag) }
                    }
                    .padding(.vertical, 6)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.gone)
            .accessibilityLabel("Tags: \(task.tags.joined(separator: ", ")). Change")
            .accessibilityIdentifier("task.tags")
        }
    }

    private func pickDate() {
        guard let controller = model.controller else { return }
        let due = TodoDates.due(task.due)
        let picker = TodoDatePicker.make(date: due?.date, hasTime: due?.hasTime ?? false, rings: task.whoKind != .bot) { [weak model] date, hasTime in
            model?.setDue(date, hasTime: hasTime)
        }
        controller.present(picker, animated: true)
    }

    /// How it repeats, once it does: a menu ("Every Week"). A task that doesn't has "+ Repeat" under the who row.
    @ViewBuilder private var repeatRow: some View {
        if let rule = task.repeatRule {
            Menu { repeatChoices } label: {
                TaskGridRow {
                    Image(systemName: "repeat").foregroundStyle(Color.hqLabel2)
                } text: {
                    Text(TodoWords.repeatLabel(rule)).foregroundStyle(Color.hqLabel).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.gone)
            .accessibilityLabel("Repeats: \(TodoWords.repeatLabel(rule)). Change")
            .accessibilityIdentifier("task.repeat")
        }
    }

    @ViewBuilder private var repeatChoices: some View {
        ForEach(TodoWords.repeatRules, id: \.self) { rule in
            Button { model.setRepeat(rule) } label: {
                if task.repeatRule == rule { Label(TodoWords.repeatLabel(rule), systemImage: "checkmark") } else { Text(TodoWords.repeatLabel(rule)) }
            }
        }
        if task.repeatRule != nil { Button("Don’t Repeat", role: .destructive) { model.setRepeat(nil) } }
    }

    /// Who has it: "Me", "Me & Hermes", "Finance", with the bot's face, and at the row's end what the bot is doing
    /// ("Working", "Has a question", "Finished its part"); on a task of your own, "Assign". A menu: Just Me, a bot
    /// with you, a bot by itself.
    private var whoRow: some View {
        let bots = PagesNames.scopeChoices(model.context.bots)
        let words = TodoViews.who(task, botName: model.botName)
        return Menu {
            Button { model.assign(.me, bot: nil) } label: {
                if task.whoKind == .me { Label("Just Me", systemImage: "checkmark") } else { Text("Just Me") }
            }
            if !bots.isEmpty {
                Section("With Me") {
                    ForEach(bots, id: \.id) { bot in
                        Button { model.assign(.together, bot: bot.id) } label: {
                            if task.whoKind == .together, task.helper == bot.id { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                        }
                    }
                }
                Section("By Itself") {
                    ForEach(bots, id: \.id) { bot in
                        Button { model.assign(.bot, bot: bot.id) } label: {
                            if task.whoKind == .bot, task.helper == bot.id { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                        }
                    }
                }
            }
        } label: {
            TaskGridRow(last: true) {
                Image(systemName: task.whoKind == .together ? "person.2" : "person").foregroundStyle(Color.hqLabel2)
            } text: {
                HStack(spacing: 6) {
                    if task.whoKind == .together { Text("Me &").foregroundStyle(Color.hqLabel) }
                    if let helper = task.helper {
                        HeadImage(raw: model.head(helper), profile: helper, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                        Text(model.botName(helper)).foregroundStyle(Color.hqLabel).lineLimit(1)
                    } else {
                        Text("Me").foregroundStyle(Color.hqLabel)
                    }
                    Spacer(minLength: 8)
                    if task.helper != nil {
                        // Only these words are drawn again each second (the chat's running turn isn't observed). The
                        // whole row in a timeline lost its menu's place: the sheet behind the open menu went blank.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let state = TodoViews.botState(task, running: model.chat?.session.isRunning == true) {
                                Text(state.words)
                                    .font(Font.hq(.footnote).weight(.medium))
                                    .foregroundStyle(TodoInk.color(state.tone))
                                    .lineLimit(1)
                                    .accessibilityIdentifier("task.bot-state")
                            }
                        }
                    } else if task.whoKind == .me, !task.isDone {
                        HStack(spacing: 3) {
                            Text("Assign")
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.gone || bots.isEmpty)
        .accessibilityLabel("Who: \(words)\(TodoViews.botState(task, running: model.chat?.session.isRunning == true).map { ", \($0.words)" } ?? ""). Change")
        .accessibilityIdentifier("task.who")
    }

    /// What isn't set yet, as quiet words under the who row, always one line: "+ Notes  + Repeat  + Priority  + Tags
    /// + More". As many as fit show as words, in this order; the rest are under "+ More". Each goes once it is set
    /// (it has its own row then). Two lines of them on a new task read as clutter (2026-11-12).
    enum Unset: Hashable { case notes, repeats, priority, tags, start, file }

    private var unset: [Unset] {
        guard !task.isDone, !model.gone else { return [] }
        var out: [Unset] = []
        if task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.editingNotes { out.append(.notes) }
        // Your own task repeats; one you share does on an add-on that keeps it (0.9.53). A bot's own never does.
        if task.repeatRule == nil, task.whoKind == .me || (task.whoKind == .together && model.hasFields) { out.append(.repeats) }
        if model.hasFields {
            if task.priority == 0 { out.append(.priority) }
            if task.tags.isEmpty { out.append(.tags) }
            if task.starts == nil { out.append(.start) }
        }
        if model.canAttach, TodoWords.shownMade(task).isEmpty { out.append(.file) }
        return out
    }

    @ViewBuilder private var moreRow: some View {
        let items = unset
        if !items.isEmpty {
            // The first line that fits: every word, else one fewer with the rest under "+ More", and so on.
            ViewThatFits(in: .horizontal) {
                moreLine(items, shown: 6)
                moreLine(items, shown: 5)
                moreLine(items, shown: 4)
                moreLine(items, shown: 3)
                moreLine(items, shown: 2)
                moreLine(items, shown: 1)
            }
            .buttonStyle(.plain)
            .padding(.leading, TaskGrid.text).padding(.trailing, TaskGrid.edge)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moreLine(_ items: [Unset], shown: Int) -> some View {
        // "+ More" never stands for one thing alone: that one is shown as its own word.
        let count = items.count - shown == 1 ? items.count : min(shown, items.count)
        let rest = Array(items.dropFirst(count))
        return HStack(spacing: 18) {
            ForEach(items.prefix(count), id: \.self) { item in moreWord(item) }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest, id: \.self) { item in moreEntry(item) }
                } label: { more("+ More") }
                    .accessibilityLabel("More to Add")
                    .accessibilityIdentifier("task.more.add")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func moreWord(_ item: Unset) -> some View {
        switch item {
        case .notes:
            Button { model.editNotes() } label: { more("+ Notes") }
                .accessibilityLabel("Add Notes")
                .accessibilityIdentifier("task.notes.add")
        case .repeats:
            Menu { repeatChoices } label: { more("+ Repeat") }
                .accessibilityLabel("Repeat")
                .accessibilityIdentifier("task.repeat.add")
        case .priority:
            Menu { priorityChoices } label: { more("+ Priority") }
                .accessibilityLabel("Priority")
                .accessibilityIdentifier("task.priority.add")
        case .tags:
            Button { model.editTags() } label: { more("+ Tags") }
                .accessibilityLabel("Add Tags")
                .accessibilityIdentifier("task.tags.add")
        case .start:
            Menu { startChoices } label: { more("+ Start date") }
                .accessibilityLabel("Start Date")
                .accessibilityIdentifier("task.start.add")
        case .file:
            Menu { fileChoices } label: { more(model.attaching ? "Adding…" : "+ File") }
                .disabled(model.attaching)
                .accessibilityLabel("Add a File, Photo or Link")
                .accessibilityIdentifier("task.file.add")
        }
    }

    /// The same thing as a line of the "+ More" menu.
    @ViewBuilder private func moreEntry(_ item: Unset) -> some View {
        switch item {
        case .notes: Button { model.editNotes() } label: { Label("Notes", systemImage: "note.text") }
        case .repeats: Menu { repeatChoices } label: { Label("Repeat", systemImage: "repeat") }
        case .priority: Menu { priorityChoices } label: { Label("Priority", systemImage: "flag") }
        case .tags: Button { model.editTags() } label: { Label("Tags…", systemImage: "tag") }
        case .start: Menu { startChoices } label: { Label("Start Date", systemImage: "calendar.badge.clock") }
        case .file: Menu { fileChoices } label: { Label("File, Photo or Link", systemImage: "paperclip") }
        }
    }

    private func more(_ words: String) -> some View {
        Text(words)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
            .lineLimit(1)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var fileChoices: some View {
        Button { model.choosePhoto() } label: { Label("Photo", systemImage: "photo") }
        Button { model.chooseFile() } label: { Label("File", systemImage: "folder") }
        Button { model.addLink() } label: { Label("Link", systemImage: "link") }
    }

    // MARK: Notes

    /// The notes: whole while they are short; longer than three lines they fold to three, with More at the heading's
    /// end (owner 2026-11-12, a bot's twenty-line brief filling the page above the steps: "The notes section takes up
    /// WAY too much space"). A tap on them starts writing (they are whole then); a tap on a link in them opens it.
    @ViewBuilder private var notes: some View {
        let filled = !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.editingNotes || filled {
            let long = !model.editingNotes && AttributedTextView.exceeds(
                TodoRich.attributed(task.notes, style: .callout, category: UIContentSizeCategory(typeSize)), lines: Self.notesFold, width: notesWidth)
            TaskBand()
            TaskSectionHead(title: "Notes", count: nil) {
                if long {
                    Button {
                        PagesHaptics.selection()
                        HQMotion.withAnimation(.snappy) { notesOpen.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(notesOpen ? "Less" : "More")
                            Image(systemName: notesOpen ? "chevron.up" : "chevron.down").imageScale(.small)
                        }
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(notesOpen ? "Show Less of the Notes" : "Show All the Notes")
                    .accessibilityIdentifier("task.notes.more")
                }
            }
            Group {
                if model.editingNotes {
                    TextField("Notes", text: $model.notes, axis: .vertical)
                        .lineLimit(2...14)
                        .font(Font.hq(.callout))
                        .focused($focus, equals: .notes)
                        .onAppear { focus = .notes }
                        .onChange(of: focus) { old, new in if old == .notes, new != .notes { model.saveNotes() } }
                        .id("task.notes")
                        .accessibilityIdentifier("task.notes")
                } else {
                    TodoRichTextView(text: task.notes, style: .callout, maxLines: long && !notesOpen ? Self.notesFold : 0,
                                     identifier: "task.notes.text",
                                     onTap: model.gone || task.isDone ? nil : { model.editNotes() }, open: model.openPath)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { notesWidth = $0 }
                        .accessibilityHint("Double-tap to edit")
                    .accessibilityAction(named: "Edit Notes") { model.editNotes() }
                }
            }
            .padding(.horizontal, TaskGrid.edge).padding(.bottom, 10)
        }
    }

    // MARK: Steps

    /// Open steps first, then Add step, then the finished ones crossed out (Todoist's order).
    @ViewBuilder private func steps(_ proxy: ScrollViewProxy) -> some View {
        if !(task.isDone && task.steps.isEmpty) {
            let open = task.steps.filter { !$0.done }, done = task.steps.filter(\.done)
            // Your next open step on a task you share: its "Me" in the accent.
            let yours = task.whoKind == .me ? nil : open.first { $0.who != "bot" }?.id
            TaskBand()
            TaskSectionHead(title: "Steps", count: task.steps.isEmpty ? nil : "\(done.count)/\(task.steps.count)") { EmptyView() }
            ForEach(open) { step in stepRow(step, yours: step.id == yours, last: false) }
            if !model.gone, !task.isDone {
                if model.addingStep {
                    TaskGridRow(last: done.isEmpty) {
                        Image(systemName: "circle").font(Font.hq(.title3).weight(.light)).foregroundStyle(Color.hqLabel3)
                    } text: {
                        TextField("Add step", text: $model.newStep)
                            .focused($focus, equals: .step)
                            .submitLabel(.done)
                            .onSubmit { model.addStep(); focus = .step }
                            .onAppear { focus = .step }
                            .onChange(of: focus) { old, new in if old == .step, new != .step { model.addingStep = false } }
                            .accessibilityIdentifier("task.add-step")
                    }
                    .id("task.add-step")
                    .onAppear { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("task.add-step", anchor: .bottom) } } }
                } else {
                    Button { PagesHaptics.selection(); model.addingStep = true } label: {
                        TaskGridRow(last: done.isEmpty) {
                            Image(systemName: "plus").foregroundStyle(Color.hqTintText)
                        } text: {
                            Text("Add step").foregroundStyle(Color.hqTintText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a Step")
                    .accessibilityIdentifier("task.steps.add")
                }
            }
            ForEach(Array(done.enumerated()), id: \.element.id) { index, step in
                stepRow(step, yours: false, last: index == done.count - 1)
            }
        }
    }

    private func stepRow(_ step: TodoStep, yours: Bool, last: Bool) -> some View {
        let bot = step.who == "bot"
        let shared = task.whoKind != .me || bot
        let long = step.title.count > TodoSheetView.stepFold
        return TaskGridRow(last: last) {
            Button { model.toggleStep(step) } label: {
                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(.title3).weight(.light))
                    .foregroundStyle(Color.hqLabel3)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.done ? "Done" : "Not done")
        } text: {
            HStack(alignment: .center, spacing: 8) {
                Text(step.title)
                    .foregroundStyle(step.done ? Color.hqLabel3 : Color.hqLabel)
                    .strikethrough(step.done, color: Color.hqLabel3)
                    .lineLimit(long && !model.openSteps.contains(step.id) ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if long { HQMotion.withAnimation(.snappy) { model.toggleOpen(step) } } }
                    .accessibilityIdentifier("task.step.title")
                // Whose it is, on a task you share: the bot's face on its steps, "Me" on yours.
                if shared {
                    if bot, let helper = task.helper {
                        HeadImage(raw: model.head(helper), profile: helper, size: 16).frame(width: 16, height: 16)
                            .opacity(step.done ? 0.6 : 1)
                            .accessibilityLabel("\(model.botName(helper))’s")
                    } else {
                        Text("Me")
                            .font(Font.hq(.footnote).weight(yours ? .semibold : .regular))
                            .foregroundStyle(yours ? Color.hqTintText : Color.hqLabel2)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityLabel(yours ? "Yours, next" : "Yours")
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(step.done ? "Mark Not Done" : "Mark Done", systemImage: step.done ? "circle" : "checkmark.circle") { model.toggleStep(step) }
            if task.whoKind != .me {
                if bot {
                    Button("Take It Myself", systemImage: "person") { model.setStepWho(step, "me") }
                } else {
                    Button("Give to \(model.botName(task.helper))", systemImage: "sparkles") { model.setStepWho(step, "bot") }
                }
            }
            Button("Delete Step", systemImage: "trash", role: .destructive) { model.deleteStep(step) }
        }
    }

    // MARK: Files

    /// What is attached to the task: your own files, photos and links, and what its bot made for it (each of those
    /// with the bot's face at its end). The last row adds one; with nothing attached the section isn't there, and
    /// "+ File" waits with the quiet words under the who row.
    @ViewBuilder private var files: some View {
        let made = TodoWords.shownMade(task)
        if !made.isEmpty {
            let adds = model.canAttach
            TaskBand()
            TaskSectionHead(title: "Files", count: "\(made.count)") { EmptyView() }
            ForEach(Array(made.enumerated()), id: \.element.id) { index, item in
                Button { model.open(item) } label: {
                    TaskGridRow(last: index == made.count - 1 && !adds) {
                        Image(systemName: TodoSheetView.madeLook(item).symbol).foregroundStyle(Color.hqLabel2)
                    } text: {
                        HStack(spacing: 8) {
                            Text(TaskPlainView.fileName(item)).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if !item.isYours, let helper = task.helper {
                                HeadImage(raw: model.head(helper), profile: helper, size: 16).frame(width: 16, height: 16)
                                    .accessibilityLabel("From \(model.botName(helper))")
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Share…", systemImage: "square.and.arrow.up") { model.share(item) }
                    if model.store.filesSupported, !model.gone {
                        Button("Remove", systemImage: "trash", role: .destructive) { model.remove(item) }
                    }
                }
                .accessibilityIdentifier("task.made.\(item.kind)")
            }
            if adds {
                Menu { fileChoices } label: {
                    TaskGridRow(last: true) {
                        if model.attaching { ProgressView().controlSize(.small) } else { Image(systemName: "plus").foregroundStyle(Color.hqTintText) }
                    } text: {
                        Text(model.attaching ? "Adding…" : "Add a file, photo or link").foregroundStyle(model.attaching ? Color.hqLabel2 : Color.hqTintText)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.attaching)
                .accessibilityLabel("Add a File, Photo or Link")
                .accessibilityIdentifier("task.files.add")
            }
        }
    }
}

extension TaskPlainView {
    /// What a file, link or note is called on the page: its title; a link with no name of its own shows its address
    /// without "https://" ("irs.gov/forms").
    static func fileName(_ item: TodoMade) -> String {
        let title = item.title.isEmpty ? item.ref : item.title
        guard item.kind == "link", title == item.ref else { return title }
        for scheme in ["https://", "http://"] where title.lowercased().hasPrefix(scheme) {
            let bare = String(title.dropFirst(scheme.count))
            return bare.hasSuffix("/") ? String(bare.dropLast()) : bare
        }
        return title
    }
}

/// [tasks-first] A tag on the task's page: a small soft pill.
struct TaskTagPill: View {
    var tag: String
    var body: some View {
        Text(tag)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Color(uiColor: TaskPanel.band)))
    }
}

/// [tasks-first] The task view's one-line message box (owner 2026-11-12, mockup 4: "One-line message box, only on a
/// task with a bot. It grows into the full box … when you tap it"): the whole line is one button that gives the chat
/// the screen with its own box and the keys up.
struct TaskMessageLine: View {
    var name: String
    /// What you had started to write in the chat's box: it shows here, so it isn't forgotten.
    var draft: String? = nil
    var action: () -> Void
    static let height: CGFloat = 62

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(draft ?? "Message \(name)")
                    .font(Font.hq(.callout))
                    .foregroundStyle(draft == nil ? Color.hqLabel2 : Color.hqLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.circle.fill")
                    .font(Font.hq(.title2))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous).fill(Color.hqFill3)
                } else {
                    Capsule().fill(Color(uiColor: TaskPanel.card))
                        .overlay { Capsule().strokeBorder(Color(uiColor: TaskPanel.edge), lineWidth: 1) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8).padding(.bottom, 8)
        .frame(height: Self.height)
        .background(Color(uiColor: TaskPanel.fill))
        .accessibilityLabel("Message \(name)")
        .accessibilityValue(draft ?? "")
        .accessibilityHint("Opens the chat")
        .accessibilityIdentifier("task.message")
    }
}

/// [tasks-first] The bot on the task, in its two places. `.ask`: under the who row, only while it waits on an answer
/// from you: who asks and since when, its words, and its answers across the page's width (the best filled, the others
/// tinted; owner 2026-11-09). `.foot`: the page's last section, like the comments under a task in Asana: the bot's
/// name and face, when it spoke, the way into the whole chat, then its latest word, what it just changed and when it
/// looks again. Redrawn every second (the chat's turn has no observation of its own).
struct TaskTeammate: View {
    enum Part { case ask, foot }
    @Bindable var model: TodoSheetModel
    let task: TodoTask
    var part: Part
    /// The timeline's tick: a new value each second draws the section again.
    var tick = Date()
    @State private var wasRunning = false

    var body: some View {
        let running = model.chat?.session.isRunning == true
        let profile = model.chatBot(task)
        let name = model.botName(profile)
        let summary = task.page?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = TodoViews.asksYou(task) && !running
        // Its question (the line it wrote with needs_you), unless its page already says the same. A ready task's line
        // only restates its page ("No reply yet; a nudge is drafted"), so it stands only where there is no page.
        let question = task.status == "needs_you" && !note.isEmpty && !summary.contains(note) ? note : nil
        let latest = model.glimpse()
        let count = model.chat?.session.messages.filter {
            ($0.role == .user || $0.role == .assistant) && !ChatText.trimmed($0.plainText).isEmpty
        }.count ?? 0
        // Its words: its Task Page's summary, else its line; with neither, the chat's newest message.
        let words: String? = {
            if !summary.isEmpty { return summary }
            if question == nil, !note.isEmpty { return note }
            if question == nil, let latest { return latest.mine ? "You: \(latest.words)" : latest.words }
            return nil
        }()
        let answer = model.sentAnswer.flatMap { running || $0.rev == task.rev ? $0.words : nil }
        let choices = asks ? Array(task.choices.prefix(3)) : []
        Group {
            switch part {
            case .ask:
                if asks, words != nil || question != nil || !choices.isEmpty {
                    askCard(name: name, profile: profile, words: words, question: question, choices: choices)
                }
            case .foot:
                foot(name: name, profile: profile, running: running, asks: asks, words: words, question: question,
                     answer: answer, latest: latest, count: count)
            }
        }
        .onChange(of: running) { _, now in
            // The turn ended: read the list now, so what the bot changed shows at once.
            if part == .foot, wasRunning, !now { Task { await model.store.refresh(force: true) } }
            wasRunning = now
        }
        .onAppear { wasRunning = running }
    }

    /// The bot's question, set off as one soft card in its state's colour, under the who row.
    private func askCard(name: String, profile: String, words: String?, question: String?, choices: [String]) -> some View {
        let tone: TodoTone = task.status == "needs_you" ? .needsYou : .ready
        let ink = TodoInk.color(tone)
        let since = TodoWords.stateTime(task, now: Date())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                HeadImage(raw: model.head(profile), profile: profile, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                Text(task.status == "needs_you" ? "\(name) asks" : "\(name) finished its part")
                    .font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(ink)
                if let since { Text("· \(since)").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            if let words { TodoRichTextView(text: words, style: .callout, identifier: "task.words", open: model.openPath) }
            if let question {
                Text(question)
                    .font(Font.hq(.callout).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task.question")
            }
            if !choices.isEmpty { answers(choices, name: name).padding(.top, 2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
                .fill(ink.opacity(0.10))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6).padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.ask")
    }

    /// The bot's section at the page's foot.
    @ViewBuilder private func foot(name: String, profile: String, running: Bool, asks: Bool, words: String?, question: String?,
                                   answer: String?, latest: TodoSheetModel.Glimpse?, count: Int) -> some View {
        // What it changed, while it is news (ten minutes): the steps and the date already show where things stand.
        let changes = TodoWords.recentChanges(task, within: 600)
        let next = task.isDone ? nil : TodoWords.nextLine(task)?.text
        let later = TodoWords.nextCheckLine(task)
        let unread = latest.map { model.isUnread($0) } ?? false
        // Its words stand here unless they are already in its card under the who row.
        let said = asks ? nil : words
        let says = said != nil || (!asks && question != nil) || answer != nil
        TaskBand()
        HStack(alignment: .center, spacing: 8) {
            HeadImage(raw: model.head(profile), profile: profile, size: 20).frame(width: 20, height: 20).accessibilityHidden(true)
            Text(name).font(Font.hq(.callout).weight(.bold)).foregroundStyle(Color.hqLabel).lineLimit(1)
            if let since = task.isDone ? nil : TodoWords.stateTime(task, now: Date()) {
                Text(since).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { model.showChat() } label: {
                HStack(spacing: 4) {
                    if unread { Circle().fill(Color.hqTint).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(unread ? "New reply" : (count > 0 ? "\(count) \(count == 1 ? "message" : "messages")" : "Open chat"))
                    Image(systemName: "chevron.right").font(Font.hq(.caption2).weight(.semibold))
                }
                .font(Font.hq(.subheadline).weight(unread ? .semibold : .regular))
                .foregroundStyle(unread ? Color.hqTintText : Color.hqLabel2)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the chat")
            .accessibilityIdentifier("task.chat-line")
        }
        .padding(.horizontal, TaskGrid.edge)
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        VStack(alignment: .leading, spacing: 6) {
            if let answer {
                Text("You: \(answer)").foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("task.answered")
            }
            if running, answer != nil {
                Text("\(name) is on it…").foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("task.working")
            } else if says {
                if let said { TodoRichTextView(text: said, style: .callout, identifier: "task.words", open: model.openPath) }
                if !asks, let question {
                    Text(question).fontWeight(.semibold).foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("task.question")
                }
            } else if !asks, count == 0, !task.isDone {
                Text("Ask anything about this task.").foregroundStyle(Color.hqLabel2)
            }
            if let next {
                Text(next).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task.next")
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { _, line in
                Label { Text(line).lineLimit(2) } icon: { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: TodoInk.ready)) }
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("task.change")
            }
            if let later {
                Label(later, systemImage: "clock")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("task.next-check")
            }
        }
        .font(Font.hq(.callout))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TaskGrid.edge).padding(.bottom, 10)
    }

    /// The bot's answers, edge to edge (owner 2026-11-09, on the small left-aligned button with words under it: "have
    /// this section fill the entire width of the screen and always be able to fill the width … a primary button and
    /// only two secondary buttons … designed a little bit differently"): the best answer filled, the others tinted, all
    /// one height, sharing the card's width (`TaskAnswerRow`).
    private func answers(_ choices: [String], name: String) -> some View {
        TaskAnswerRow(spacing: 8) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button { model.answer(choice) } label: {
                    Text(choice)
                        .font(Font.hq(.subheadline).weight(index == 0 ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(index == 0 ? Color.hqOnTint : Color.hqTintText)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(index == 0 ? Color.hqTint : Color(uiColor: TaskPanel.fill)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sends “\(choice)” to \(name)")
                .accessibilityIdentifier("task.choice.\(index)")
            }
        }
    }
}

/// [tasks] The answers' row: it always fills the width it is given. All on one row when their words fit, what's left
/// over shared between them; else the first (the best answer) across the whole width with the others sharing the row
/// under it; else one under another.
struct TaskAnswerRow: Layout {
    var spacing: CGFloat = 8

    private func rows(_ ideal: [CGFloat], width: CGFloat) -> [[Int]] {
        let all = Array(ideal.indices)
        guard ideal.count > 1 else { return [all] }
        if ideal.reduce(0, +) + spacing * CGFloat(ideal.count - 1) <= width + 0.5 { return [all] }
        let rest = Array(all.dropFirst())
        let share = (width - spacing * CGFloat(rest.count - 1)) / CGFloat(rest.count)
        if rest.allSatisfy({ ideal[$0] <= share + 0.5 }) { return [[0], rest] }
        return all.map { [$0] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? (ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(ideal.count - 1, 0)))
        let lines = rows(ideal.map(\.width), width: width)
        let height = lines.map { line in line.map { ideal[$0].height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in rows(ideal.map(\.width), width: bounds.width) {
            let height = line.map { ideal[$0].height }.max() ?? 0
            let free = bounds.width - spacing * CGFloat(line.count - 1)
            let wanted = line.map { ideal[$0].width }.reduce(0, +)
            // One row: each takes what its words need plus an equal part of what's left. A row of its own or a shared
            // second row: equal parts of the width.
            let extra = line.count == subviews.count && wanted <= free ? (free - wanted) / CGFloat(line.count) : nil
            var x = bounds.minX
            for index in line {
                let width = extra.map { ideal[index].width + $0 } ?? free / CGFloat(line.count)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
                x += width + spacing
            }
            y += height + spacing
        }
    }
}

/// The page's two left edges (Todoist's): an icon column, then one text column all the way down.
enum TaskGrid {
    static let edge: CGFloat = 20
    static let icon: CGFloat = 24
    static let gap: CGFloat = 14
    /// Where the text column starts.
    static var text: CGFloat { edge + icon + gap }
}

/// One row on the grid: its icon centred in the icon column, its words in the text column, a thin line under the words
/// unless it is the last of its group.
struct TaskGridRow<Icon: View, Words: View>: View {
    var last = false
    var topLine = false
    var minHeight: CGFloat = 40
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var text: () -> Words

    var body: some View {
        HStack(alignment: .center, spacing: TaskGrid.gap) {
            icon()
                .font(Font.hq(.callout))
                .frame(width: TaskGrid.icon)
            text()
                .font(Font.hq(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TaskGrid.edge)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { if topLine { TaskPlainHairline().padding(.leading, TaskGrid.text).padding(.trailing, TaskGrid.edge) } }
        .overlay(alignment: .bottom) { if !last { TaskPlainHairline().padding(.leading, TaskGrid.text).padding(.trailing, TaskGrid.edge) } }
    }
}

/// A section's heading: bold, with its count (or when) in grey beside it, and one quiet thing at its end.
struct TaskSectionHead<Trailing: View>: View {
    var title: String
    var count: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Font.hq(.callout).weight(.bold)).foregroundStyle(Color.hqLabel).lineLimit(1)
            if let count { Text(count).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, TaskGrid.edge)
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
    }
}

/// The band between two sections, edge to edge.
struct TaskBand: View {
    var body: some View {
        Rectangle().fill(Color(uiColor: TaskPanel.band)).frame(height: 8).padding(.top, 2).accessibilityHidden(true)
    }
}

/// A thin rule on the task's page.
struct TaskPlainHairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(Color(uiColor: TaskPanel.edge)).frame(height: 1 / max(scale, 1)).accessibilityHidden(true)
    }
}
