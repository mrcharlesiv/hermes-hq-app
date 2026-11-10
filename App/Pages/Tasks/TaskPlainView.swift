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
    enum Field: Hashable { case step, notes }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    TimelineView(.periodic(from: .now, by: 1)) { _ in standingRow }
                    dueRow
                    checkRow
                    askRow
                    if model.gone {
                        TaskGridRow(last: true) { Image(systemName: "trash") } text: {
                            Text("This task was deleted.").foregroundStyle(Color.hqLabel2)
                        }
                    }
                    // The tick is passed in so the section is drawn again each second (the chat's messages and its
                    // running turn aren't observed).
                    TimelineView(.periodic(from: .now, by: 1)) { context in TaskPlainUpdate(model: model, task: task, tick: context.date) }
                    notes
                    steps(proxy)
                }
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // What the page draws, said at once and on every change (the scroll view's own geometry said nothing
                // until something changed, so a page that drew right the first time kept its starting height).
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onLeadHeight?($0) }
            }
            .scrollDisabled(!model.briefScrolls)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.editingNotes) { _, editing in
                if editing { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("task.notes", anchor: .bottom) } } }
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
    }

    // MARK: Top

    /// The circle (finishes it, or opens it again) and the title, at the page's own scale.
    private var titleRow: some View {
        TaskGridRow(last: true, minHeight: 46) {
            Button { task.isDone ? model.reopen() : model.markDone() } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(.title2).weight(.light))
                    .foregroundStyle(task.isDone ? Color.hqTint : Color.hqLabel3)
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

    /// Where it stands, in its state's colour: "Ready for you", "Hermes is on it", "Completed today, 11:40 AM". A task
    /// still to do has no such row. A tap shows its History.
    @ViewBuilder private var standingRow: some View {
        let running = model.chat?.session.isRunning == true
        let words: String? = {
            if task.isDone { return TaskBarView.completed(task) }
            if running { return "\(model.botName(TodoSheetView.speaker(task))) is on it" }
            return task.status == "open" ? nil : TodoWords.stateWords(task, botName: model.botName)
        }()
        if let words {
            let color = running && !task.isDone ? Color.hqTintText : TodoSheetView.statusColor(task.status)
            Button { model.showHistory() } label: {
                TaskGridRow {
                    Circle().fill(color).frame(width: 10, height: 10)
                } text: {
                    Text(words).fontWeight(.semibold).foregroundStyle(color).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the task’s history")
            .accessibilityIdentifier("task.standing")
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
        return Menu {
            Button("Today") { model.setDue(now, hasTime: false) }
            Button("Tomorrow") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…") { pickDate() }
            if due != nil { Button("No Due Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            TaskGridRow(last: TodoWords.nextCheckLine(task) == nil) {
                Image(systemName: "calendar").foregroundStyle(due == nil || color == Color.hqLabel ? Color.hqLabel2 : color)
            } text: {
                Text(words).foregroundStyle(due == nil ? Color.hqLabel3 : color).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Due: \(words). Change")
        .accessibilityIdentifier("task.due")
    }

    private func pickDate() {
        guard let controller = model.controller else { return }
        let due = TodoDates.due(task.due)
        let picker = TodoDatePicker.make(date: due?.date, hasTime: due?.hasTime ?? false, rings: task.whoKind != .bot) { [weak model] date, hasTime in
            model?.setDue(date, hasTime: hasTime)
        }
        controller.present(picker, animated: true)
    }

    /// When its bot looks at it again by itself ("Checks again tomorrow, 9:00 AM"): a detail of the task, like its date.
    @ViewBuilder private var checkRow: some View {
        if let later = TodoWords.nextCheckLine(task) {
            TaskGridRow(last: true) {
                Image(systemName: "clock").foregroundStyle(Color.hqLabel2)
            } text: {
                Text(later).foregroundStyle(Color.hqLabel).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task.next-check")
        }
    }

    /// A task nobody has started on: one row that asks its bot to help, or to start.
    @ViewBuilder private var askRow: some View {
        if model.chat?.session.isRunning != true, let now = TaskNow.pick(task, phone: nil, deleted: model.gone),
           let action = [now.primary, now.secondary].compactMap({ $0 }).first(where: { $0 == .askHelp || $0 == .askStart }) {
            let words = action.label(botName: model.botName(model.chatBot(task)))
            Button { model.perform(action, task: task) } label: {
                TaskGridRow(last: true, topLine: true) {
                    Image(systemName: action.symbol).foregroundStyle(Color.hqTintText)
                } text: {
                    Text(words).foregroundStyle(Color.hqTintText).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(action.identifier)
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        let filled = !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.editingNotes || filled {
            TaskBand()
            TaskSectionHead(title: "Notes", count: nil) {
                if !model.editingNotes {
                    Button("Edit") { model.editNotes() }
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqTintText)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit Notes")
                        .accessibilityIdentifier("task.notes.edit")
                }
            }
            Group {
                if model.editingNotes {
                    TextField("Notes", text: $model.notes, axis: .vertical)
                        .lineLimit(2...10)
                        .font(Font.hq(.callout))
                        .focused($focus, equals: .notes)
                        .onAppear { focus = .notes }
                        .onChange(of: focus) { old, new in if old == .notes, new != .notes { model.saveNotes() } }
                        .id("task.notes")
                        .accessibilityIdentifier("task.notes")
                } else {
                    TodoFoldedText(text: task.notes, lines: 4, identifier: "task.notes.text", open: model.openPath)
                }
            }
            .padding(.horizontal, TaskGrid.edge).padding(.bottom, 8)
        }
    }

    // MARK: Steps

    /// Open steps first, then Add step, then the finished ones crossed out (Todoist's order).
    @ViewBuilder private func steps(_ proxy: ScrollViewProxy) -> some View {
        if !(task.isDone && task.steps.isEmpty) {
            let open = task.steps.filter { !$0.done }, done = task.steps.filter(\.done)
            // Your next open step on a task you share: its "You" in the accent.
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
        let owner: String? = task.whoKind == .me && !bot ? nil : (bot ? model.botName(task.helper) : "You")
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title)
                    .foregroundStyle(step.done ? Color.hqLabel3 : Color.hqLabel)
                    .strikethrough(step.done, color: Color.hqLabel3)
                    .lineLimit(long && !model.openSteps.contains(step.id) ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if long { HQMotion.withAnimation(.snappy) { model.toggleOpen(step) } } }
                    .accessibilityIdentifier("task.step.title")
                if let owner {
                    Text(owner)
                        .font(Font.hq(.footnote).weight(yours ? .semibold : .regular))
                        .foregroundStyle(yours ? Color.hqTintText : Color.hqLabel2)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(yours ? "Yours, next" : "\(owner)’s")
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
}

/// [tasks] The bot's section, on the page's own rows (owner 2026-11-09: the middle section was "too big and has a
/// different layout than the top part"): its name as the heading, when it spoke and the way into the whole chat; then
/// its latest word beside its face, each thing it made as a plain row, and its answers across the page's width (the
/// best filled, the others tinted). What it just changed shows for a few minutes as a row; when it looks again is a
/// row in the details at the top. Redrawn every second (the chat's turn has no observation of its own).
struct TaskPlainUpdate: View {
    @Bindable var model: TodoSheetModel
    let task: TodoTask
    /// The timeline's tick: a new value each second draws the section again.
    var tick = Date()
    @State private var wasRunning = false

    var body: some View {
        let running = model.chat?.session.isRunning == true
        let profile = model.chatBot(task)
        let summary = task.page?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = task.statusNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let asks = !task.isDone && (task.status == "needs_you" || task.status == "ready")
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
        let made = TodoWords.shownMade(task)
        // What it changed, while it is news (ten minutes): the steps and the date already show where things stand.
        let changes = TodoWords.recentChanges(task, within: 600)
        let answer = model.sentAnswer.flatMap { running || $0.rev == task.rev ? $0.words : nil }
        let choices = asks && !running ? Array(task.choices.prefix(3)) : []
        let next = task.isDone || TodoWords.nextCheckLine(task) != nil ? nil : TodoWords.nextLine(task)?.text
        let says = words != nil || question != nil || next != nil || answer != nil
        let shows = says || !made.isEmpty || !changes.isEmpty || !choices.isEmpty || count > 0
        let unread = latest.map { model.isUnread($0) } ?? false
        let tail = !made.isEmpty || !changes.isEmpty || !choices.isEmpty   // rows follow its words
        Group {
            if shows {
                TaskBand()
                TaskSectionHead(title: model.botName(profile), count: task.isDone ? nil : TodoWords.stateTime(task, now: Date())) {
                    if count > 0 {
                        Button { model.showChat() } label: {
                            HStack(spacing: 4) {
                                if unread { Circle().fill(Color.hqTint).frame(width: 7, height: 7).accessibilityHidden(true) }
                                Text(unread ? "New reply" : "All \(count) \(count == 1 ? "message" : "messages")")
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
                }
                if says {
                    HStack(alignment: .top, spacing: TaskGrid.gap) {
                        HeadImage(raw: model.head(profile), profile: profile, size: TaskGrid.icon)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            if let answer {
                                Text("You: \(answer)").foregroundStyle(Color.hqLabel2)
                                    .accessibilityIdentifier("task.answered")
                            }
                            if running, answer != nil {
                                Text("\(model.botName(profile)) is on it…").foregroundStyle(Color.hqLabel2)
                                    .accessibilityIdentifier("task.working")
                            } else {
                                if let words { TodoRichTextView(text: words, identifier: "task.words", open: model.openPath) }
                                if let question {
                                    Text(question)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.hqLabel)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("task.question")
                                }
                                if let next {
                                    Text(next).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("task.next")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Font.hq(.callout))
                    .padding(.horizontal, TaskGrid.edge).padding(.bottom, 10)
                    .overlay(alignment: .bottom) {
                        if tail { TaskPlainHairline().padding(.leading, TaskGrid.text).padding(.trailing, TaskGrid.edge) }
                    }
                }
                ForEach(Array(made.enumerated()), id: \.element.id) { index, item in
                    madeRow(item, last: index == made.count - 1 && changes.isEmpty && choices.isEmpty)
                }
                ForEach(Array(changes.enumerated()), id: \.offset) { index, line in
                    TaskGridRow(last: index == changes.count - 1 && choices.isEmpty) {
                        Image(systemName: "checkmark").foregroundStyle(Color(uiColor: TodoInk.ready))
                    } text: {
                        Text(line).foregroundStyle(Color.hqLabel2).lineLimit(2)
                    }
                    .accessibilityIdentifier("task.change")
                }
                if !choices.isEmpty { answers(choices, name: model.botName(profile)) }
            }
        }
        .onChange(of: running) { _, now in
            // The turn ended: read the list now, so what the bot changed shows at once.
            if wasRunning, !now { Task { await model.store.refresh(force: true) } }
            wasRunning = now
        }
        .onAppear { wasRunning = running }
    }

    /// What the bot made, as a row like any other: its kind's icon, its name, an arrow.
    private func madeRow(_ made: TodoMade, last: Bool) -> some View {
        Button { model.open(made) } label: {
            TaskGridRow(last: last) {
                Image(systemName: TodoSheetView.madeLook(made).symbol).foregroundStyle(Color.hqLabel2)
            } text: {
                HStack(spacing: 8) {
                    Text(made.title.isEmpty ? made.ref : made.title).foregroundStyle(Color.hqLabel).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel3)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Share…", systemImage: "square.and.arrow.up") { model.share(made) } }
        .accessibilityIdentifier("task.made.\(made.kind)")
    }

    /// The bot's answers, edge to edge (owner 2026-11-09, on the small left-aligned button with words under it: "have
    /// this section fill the entire width of the screen and always be able to fill the width … a primary button and
    /// only two secondary buttons … designed a little bit differently"): the best answer filled, the others tinted, all
    /// one height, sharing the page's width (`TaskAnswerRow`).
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
                        .background(Capsule().fill(index == 0 ? Color.hqTint : Color.hqTint.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sends “\(choice)” to \(name)")
                .accessibilityIdentifier("task.choice.\(index)")
            }
        }
        .padding(.horizontal, TaskGrid.edge)
        .padding(.top, 10).padding(.bottom, 12)
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
