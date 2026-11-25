// Compact quick-capture sheet for New Task: rides over the keyboard with live natural-language parsing,
// notes directly underneath, a visible row of task chips (Date, List, Priority, Goal, Start Date, Repeat),
// and a compact teammate picker so pure task management stays front and center.

import SwiftUI
import UIKit

@MainActor @Observable
final class NewTodoModel {
    let store: TasksStore
    let bots: [Bot]
    var title = ""
    var notes = ""
    /// The bot on it (with you, or `alone`); nil: just you.
    var helper: String?
    var alone = false
    /// Keep the typed title instead of extracting fields.
    var literalTitle = false
    /// A date picked by hand: the line's date words stay in the name.
    var manualDue = false
    var hasDue = false
    var due = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)).addingTimeInterval(9 * 3600)
    var hasTime = false
    /// Optional start day (when the task joins Today).
    var starts: Date?
    var repeatRule: String?
    /// Picked on the priority button; nil: what the line says ("!high"), else none.
    var priority: Int?
    /// The list it starts in (the one on show).
    var section: String?
    /// Optional goal (and milestone) it serves.
    var goal: String?
    var milestone: String?
    var saving = false
    var failure: String?
    /// "Added “Call mom”", for a moment after a task of your own went in.
    var added: String?
    /// [goals] Counts the tasks of your own added here: each one puts the line back in focus, so the keys stay up for
    /// the next (docs/tasks.md step 4: "Add leaves the sheet open for the next task").
    var addedCount = 0
    @ObservationIgnored var onCreated: ((TodoTask?) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?
    @ObservationIgnored private var addedWork: DispatchWorkItem?
    /// The day the sheet opened on (Today's +, a day picked on Upcoming): every task added here starts there.
    @ObservationIgnored private let startDay: Date?

    init(store: TasksStore, bots: [Bot], preferredBot: String?, section: String? = nil, dueDay: Date? = nil) {
        self.store = store
        self.section = section
        startDay = dueDay
        var seen = Set<String>()
        self.bots = PagesNames.scopeChoices(bots).filter { seen.insert($0.id).inserted }
        helper = preferredBot.flatMap { id in self.bots.contains { $0.id == id } ? id : nil }
        startOver()
    }

    func botName(_ id: String) -> String { PagesNames.botName(id, bots: bots) }
    func head(_ id: String) -> JSONValue? { PagesNames.head(id, bots: bots) }
    var fields: Bool { store.fieldsSupported }
    var activeGoals: [Goal] { store.goalsSupported ? store.goals.filter { $0.state == .active } : [] }

    /// What the line says, read as it is typed.
    var read: TodoQuickRead {
        if literalTitle {
            var literal = TodoQuickRead()
            literal.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return literal
        }
        return TodoQuickParse.read(title, now: Date(), dates: !manualDue,
                                   metadata: fields && !literalTitle,
                                   repeats: !literalTitle && who != .bot && (who == .me || fields), priorities: priority == nil)
    }

    /// When it's due: the hand-picked date, else the line's, else the day the sheet opened on.
    var dueNow: (date: Date, hasTime: Bool)? {
        if manualDue { return hasDue ? (due, hasTime) : nil }
        let read = read
        if let date = read.due { return (date, read.hasTime) }
        return hasDue ? (due, hasTime) : nil
    }
    var repeatNow: String? { who == .bot ? nil : (repeatRule ?? read.repeatRule) }
    var priorityNow: Int { fields ? (priority ?? read.priority ?? 0) : 0 }
    var who: TodoWho { helper == nil ? .me : (alone ? .bot : .together) }
    var listName: String? { section.flatMap { id in store.sections.first { $0.id == id }?.name } }
    var goalName: String? { goal.flatMap { id in store.goal(id)?.title }.flatMap { $0.isEmpty ? "Untitled Goal" : $0 } }

    var whoLabel: String {
        guard let helper else { return "Just Me" }
        return alone ? botName(helper) : "You & \(botName(helper))"
    }

    var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    func setDue(_ date: Date?, hasTime: Bool) {
        PagesHaptics.selection()
        manualDue = true
        hasDue = date != nil
        if let date { due = date }
        self.hasTime = hasTime
    }

    func pickDate() {
        guard let controller else { return }
        let now = dueNow
        let picker = TodoDatePicker.make(date: now?.date, hasTime: now?.hasTime ?? false, rings: who != .bot) { [weak self] date, hasTime in
            self?.setDue(date, hasTime: hasTime)
        }
        controller.present(picker, animated: true)
    }

    func setStarts(_ date: Date?) {
        PagesHaptics.selection()
        starts = date.map { Calendar.current.startOfDay(for: $0) }
    }

    func pickStarts() {
        guard let controller else { return }
        let picker = TodoDatePicker.make(date: starts, hasTime: false, rings: false, dayOnly: true) { [weak self] date, _ in
            self?.setStarts(date)
        }
        controller.present(picker, animated: true)
    }

    func setGoal(_ id: String?, milestone: String? = nil) {
        PagesHaptics.selection()
        goal = id
        self.milestone = id == nil ? nil : milestone
    }

    func setWho(_ bot: String?, alone: Bool) {
        PagesHaptics.selection()
        helper = bot
        self.alone = bot != nil && alone
        if self.alone { repeatRule = nil }
    }

    /// The line is empty again, for the next task: the list and who stay; the date goes back to the sheet's own day.
    private func startOver() {
        title = ""
        notes = ""
        manualDue = false
        literalTitle = false
        priority = nil
        repeatRule = nil
        starts = nil
        goal = nil
        milestone = nil
        hasTime = false
        hasDue = startDay != nil
        if let startDay { due = Calendar.current.startOfDay(for: startDay).addingTimeInterval(9 * 3600) }
    }

    func add() {
        guard canAdd else { return }
        saving = true
        failure = nil
        controller?.isModalInPresentation = true
        let read = read
        let who = who
        let due = dueNow
        let cleanTitle = read.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // With a bot and you it's a shared task with nothing split yet: the bot's first turn asks which parts it takes.
        var fields = TodoWire.newTask(
            title: cleanTitle.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleanTitle,
            who: who,
            bot: helper,
            due: due.map { TodoDates.wire($0.date, hasTime: $0.hasTime) },
            repeatRule: repeatNow,
            prep: false,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            goal: store.goalsSupported ? goal : nil,
            milestone: store.goalsSupported ? milestone : nil
        )
        if who == .together, store.fieldsSupported, let rule = repeatNow { fields["repeat"] = .string(rule) }
        if store.fieldsSupported {
            if priorityNow > 0 { fields["priority"] = .number(Double(priorityNow)) }
            if !read.tags.isEmpty { fields["tags"] = .array(read.tags.map(JSONValue.string)) }
            if let starts { fields["starts"] = .string(TodoDates.wire(starts, hasTime: false)) }
        }
        if let section { fields["section"] = .string(section) }
        Task {
            let made = await store.add(fields)
            saving = false
            controller?.isModalInPresentation = false
            guard let made else {
                PagesHaptics.error()
                // The gateway's own reason (it refused, read-only, …); the connection only when there's none.
                failure = store.addFailure ?? "Check your connection, then try again."
                return
            }
            PagesHaptics.success()
            let done = onCreated
            if made.helper != nil {
                // A bot is on it: the task opens with that bot's chat.
                if let controller { controller.dismiss(animated: true) { done?(made) } } else { done?(made) }
                return
            }
            // Your own: the sheet stays for the next one.
            done?(made)
            startOver()
            addedCount += 1
            let words = "Added “\(made.title)”"
            added = words
            HQAnnounce.say(words)
            addedWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.added = nil }
            addedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }
}

enum NewTodoSheet {
    static func make(store: TasksStore, bots: [Bot], preferredBot: String?, section: String? = nil, dueDay: Date? = nil,
                     onCreated: @escaping (TodoTask?) -> Void) -> UIViewController {
        let model = NewTodoModel(store: store, bots: bots, preferredBot: preferredBot, section: section, dueDay: dueDay)
        model.onCreated = onCreated
        return NewTodoHost(model: model)
    }
}

/// Compact quick-add sheet riding over the keyboard (same shape as NewGoalHost).
final class NewTodoHost: UIHostingController<HQScaledRoot<NewTodoView>>, EditingPage, UIAdaptivePresentationControllerDelegate {
    let model: NewTodoModel
    private var fitted: CGFloat = 210

    init(model: NewTodoModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTodoView(model: model)))
        model.controller = self
        rootView = HQScaledRoot(NewTodoView(model: model, onHeight: { [weak self] in self?.fit($0) }, close: { [weak self] in self?.closeAsking() }))
        QuickAddSheet.configure(self, identifier: "tasks.new") { [weak self] in self?.fitted ?? 210 }
        presentationController?.delegate = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !hasChanges && !model.saving
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closeAsking()
    }

    private func fit(_ height: CGFloat) { QuickAddSheet.fit(self, height, fitted: fitted) { fitted = $0 } }

    // Any typed draft requires confirmation before dismissing the sheet.
    var hasChanges: Bool {
        !model.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isSaving: Bool { model.saving }

    /// ✕, Escape: closes, asking first when there is something to lose.
    func closeAsking() {
        guard !model.saving else { return }
        view.endEditing(true)
        confirmLeaving { [weak self] in self?.dismiss(animated: true) }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if model.canAdd { commands.append(.save("Add", #selector(addFromKeyboard))) }
        let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard))
        close.wantsPriorityOverSystemBehavior = true
        commands.append(close)
        return commands
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func addFromKeyboard() { model.add() }
    @objc private func closeFromKeyboard() { closeAsking() }
}

/// [goals] What a quick add's sheet is (New Task's, and New Goal's): as tall as its content, over the keyboard, on one
/// opaque card, the list dimmed behind it.
enum QuickAddSheet {
    static func configure(_ host: UIViewController, identifier: String, height: @escaping () -> CGFloat) {
        host.modalPresentationStyle = DeviceWord.isMac ? .formSheet : .pageSheet
        host.preferredContentSize = CGSize(width: 520, height: height())
        host.view.backgroundColor = HQPalette.groupedCard   // solid-ok: a quick-add bar a few rows tall riding the keyboard; its fields sit on one opaque card
        host.view.accessibilityIdentifier = identifier + ".sheet"
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init(identifier)) { _ in height() }]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.preferredCornerRadius = Theme.isDesktop ? DesktopRows.radius + 6 : nil
        }
    }

    /// The content's height changed (a second line, a note under it): the sheet follows. `store` keeps the new height
    /// before the detent is asked for it (never an `inout`: the detent reads the same property while it resolves).
    static func fit(_ host: UIViewController, _ height: CGFloat, fitted: CGFloat, store: (CGFloat) -> Void) {
        let next = max(110, height.rounded(.up))
        guard abs(next - fitted) > 0.5 else { return }
        store(next)
        host.preferredContentSize = CGSize(width: 520, height: next)
        guard let sheet = host.sheetPresentationController else { return }
        if host.view.window == nil || HQMotion.reduced {
            sheet.invalidateDetents()
        } else {
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }
}

/// [goals] One of a quick add's buttons: a capsule, tinted once it holds something.
struct QuickAddChip: View {
    var words: String?
    var symbol: String?
    var set: Bool
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(tint ?? (set ? Color.hqTintText : Color.hqLabel2)) }
            if let words { Text(words).lineLimit(1) }
        }
        .font(Font.hq(.footnote).weight(set && !DeviceWord.isMac ? .semibold : .regular))   // [type] Mac: the tint shows it is set
        .foregroundStyle(set ? Color.hqTintText : Color.hqLabel2)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Capsule().fill(set ? Color.hqTint.opacity(0.12) : Color.hqFill3))
        .contentShape(Capsule())
    }
}

/// [goals] A quick add's round Add at the end of its buttons.
struct QuickAddButton: View {
    var enabled: Bool
    var saving: Bool
    var identifier: String
    /// What VoiceOver calls it ([goals] Update's says "Update").
    var label = "Add"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Font.hq(.title).weight(.regular))
                        .foregroundStyle(enabled ? Color.hqTint : Color.hqLabel3)
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct NewTodoView: View {
    @Bindable var model: NewTodoModel
    var onHeight: (CGFloat) -> Void = { _ in }
    var close: () -> Void = {}
    @FocusState private var focus: Field?
    enum Field: Hashable { case title, notes }

    private var trimmedTitle: String { model.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let read = model.read
        let parsedDifferent = !trimmedTitle.isEmpty && (read.title != trimmedTitle || model.literalTitle)
        VStack(alignment: .leading, spacing: 0) {
            // Grabber on touch devices for visual continuity with compact sheets.
            if !DeviceWord.isMac {
                Capsule()
                    .fill(Color.hqLabel3.opacity(0.45))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("What needs to be done?", text: $model.title, axis: .vertical)
                    .lineLimit(1...3)
                    .font(Font.hq(.body).weight(.medium))
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    .onChange(of: model.title) { _, text in
                        guard text.contains("\n") else { return }
                        model.title = text.replacingOccurrences(of: "\n", with: " ")
                        model.add()
                    }
                    .accessibilityIdentifier("tasks.new.title")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.saving)
                .hqIconLabel("Close")
                .accessibilityIdentifier("sheet.close")
            }
            .padding(.top, DeviceWord.isMac ? 14 : 6)

            if parsedDifferent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.literalTitle ? "Using your title exactly as typed" : "→ “\(read.title)”\(read.tags.isEmpty ? "" : " " + read.tags.map { "#\($0)" }.joined(separator: " "))")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(model.literalTitle ? "Using your title exactly as typed" : "Will be named \(read.title)")
                        .accessibilityIdentifier("tasks.new.read")
                    Button(model.literalTitle ? "Read details" : "Keep literal") {
                        PagesHaptics.selection()
                        model.literalTitle.toggle()
                    }
                    .font(Font.hq(.footnote).weight(.medium))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks.new.literal")
                }
                .padding(.top, 4)
            }

            TextField("Notes (optional)", text: $model.notes, axis: .vertical)
                .lineLimit(1...3)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .focused($focus, equals: .notes)
                .padding(.top, 8)
                .accessibilityIdentifier("tasks.new.notes")

            // Visible one-tap task chips row (pure task management first: Date, List, Priority, Goal, Start, Repeat).
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    dateChip(read)
                    if !model.store.sections.isEmpty { listChip }
                    if model.fields { priorityChip }
                    if !model.activeGoals.isEmpty { goalChip }
                    if model.fields { startsChip }
                    if model.who != .bot && (model.who == .me || model.fields) { repeatChip }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .padding(.top, 12)

            if let failure = model.failure {
                Text(failure)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("tasks.new.failure")
            } else if let helper = model.helper {
                Text(model.alone ? "\(model.botName(helper))’s chat opens and it starts on the task right away." : TodoWords.newTaskHelpNote(model.botName(helper)))
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("tasks.new.help-note")
            } else if let added = model.added {
                Label(added, systemImage: "checkmark")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.top, 8)
                    .accessibilityIdentifier("tasks.new.added")
            }

            Divider().padding(.top, 10)

            HStack(spacing: 10) {
                if !model.bots.isEmpty {
                    whoMenu
                } else {
                    Text("Just Me")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
                Spacer(minLength: 8)
                QuickAddButton(enabled: model.canAdd, saving: model.saving, identifier: "tasks.new.add") {
                    model.add()
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .disabled(model.saving)
        .onAppear { focus = .title }
        .onChange(of: model.addedCount) { _, _ in focus = .title }
    }

    // MARK: The chips

    private func chip(_ words: String?, symbol: String?, set: Bool, tint: Color? = nil) -> some View {
        QuickAddChip(words: words, symbol: symbol, set: set, tint: tint)
    }

    private func dateChip(_ read: TodoQuickRead) -> some View {
        let now = Date()
        let due = model.dueNow
        var words = due.map { TodoWords.newTaskDue($0.date, hasTime: $0.hasTime, now: now) }
        if let rule = model.repeatNow { words = [words, TodoWords.repeatLabel(rule)].compactMap { $0 }.joined(separator: " · ") }
        return Menu {
            Button("Today", systemImage: "sun.max") { model.setDue(now, hasTime: false) }
            Button("Tomorrow", systemImage: "sunrise") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week", systemImage: "calendar") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…", systemImage: "calendar.badge.plus") { model.pickDate() }
            if due != nil { Button("No Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            chip(words ?? "Date", symbol: "calendar", set: due != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "Due \($0). Change" } ?? "Date")
        .accessibilityIdentifier("tasks.new.due")
    }

    private var listChip: some View {
        Menu {
            Button { PagesHaptics.selection(); model.section = nil } label: {
                if model.section == nil { Label("No List", systemImage: "checkmark") } else { Text("No List") }
            }
            ForEach(model.store.sections) { list in
                Button { PagesHaptics.selection(); model.section = list.id } label: {
                    if model.section == list.id { Label(list.name, systemImage: "checkmark") } else { Text(list.name) }
                }
            }
        } label: {
            let icon = model.section.flatMap { id in model.store.sections.first { $0.id == id }?.icon } ?? "tray"
            chip(model.listName ?? "List", symbol: icon, set: model.section != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.listName.map { "List: \($0). Change" } ?? "List")
        .accessibilityIdentifier("tasks.new.section")
    }

    private var priorityChip: some View {
        let level = model.priorityNow
        return Menu {
            ForEach([1, 2, 3], id: \.self) { value in
                Button { PagesHaptics.selection(); model.priority = value } label: {
                    if level == value { Label(TodoViews.priorityWord(value), systemImage: "checkmark") } else { Text(TodoViews.priorityWord(value)) }
                }
            }
            if level > 0 { Button("No Priority", role: .destructive) { PagesHaptics.selection(); model.priority = 0 } }
        } label: {
            chip(level > 0 ? TodoViews.priorityWord(level) : "Priority", symbol: level > 0 ? "flag.fill" : "flag", set: level > 0,
                 tint: TodoPriorityLook.color(level))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level > 0 ? "\(TodoViews.priorityWord(level)) priority. Change" : "Priority")
        .accessibilityIdentifier("tasks.new.priority")
    }

    private var goalChip: some View {
        Menu {
            Button { model.setGoal(nil) } label: {
                if model.goal == nil { Label("No Goal", systemImage: "checkmark") } else { Text("No Goal") }
            }
            ForEach(model.activeGoals) { goal in
                let open = goal.milestones.filter { !$0.done }
                if open.isEmpty {
                    Button { model.setGoal(goal.id) } label: {
                        if model.goal == goal.id { Label(goal.title, systemImage: "checkmark") } else { Text(goal.title) }
                    }
                } else {
                    Menu(goal.title) {
                        Button { model.setGoal(goal.id, milestone: nil) } label: {
                            if model.goal == goal.id, model.milestone == nil { Label("No Milestone", systemImage: "checkmark") } else { Text("No Milestone") }
                        }
                        ForEach(open) { milestone in
                            Button { model.setGoal(goal.id, milestone: milestone.id) } label: {
                                if model.goal == goal.id, model.milestone == milestone.id { Label(milestone.title, systemImage: "checkmark") } else { Text(milestone.title) }
                            }
                        }
                    }
                }
            }
        } label: {
            chip(model.goalName ?? "Goal", symbol: "smallcircle.filled.circle", set: model.goal != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.goalName.map { "Goal: \($0). Change" } ?? "Goal")
        .accessibilityIdentifier("tasks.new.goal")
    }

    private var startsChip: some View {
        let now = Date()
        let words = model.starts.map { "Starts " + TodoViews.soon($0, now: now) }
        return Menu {
            Button("Today", systemImage: "sun.max") { model.setStarts(now) }
            Button("Tomorrow", systemImage: "sunrise") { model.setStarts(Calendar.current.date(byAdding: .day, value: 1, to: now)) }
            Button("Next Week", systemImage: "calendar") { model.setStarts(Calendar.current.date(byAdding: .day, value: 7, to: now)) }
            Button("Choose Date…", systemImage: "calendar.badge.clock") { model.pickStarts() }
            if model.starts != nil { Button("No Start Date", role: .destructive) { model.setStarts(nil) } }
        } label: {
            chip(words ?? "Starts", symbol: "calendar.badge.clock", set: model.starts != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "\($0). Change" } ?? "Start Date")
        .accessibilityIdentifier("tasks.new.starts")
    }

    private var repeatChip: some View {
        let current = model.repeatNow
        return Menu {
            ForEach(TodoWords.repeatRules, id: \.self) { rule in
                Button { PagesHaptics.selection(); model.repeatRule = rule } label: {
                    if current == rule { Label(TodoWords.repeatLabel(rule), systemImage: "checkmark") } else { Text(TodoWords.repeatLabel(rule)) }
                }
            }
            if current != nil { Button("Don’t Repeat", role: .destructive) { PagesHaptics.selection(); model.repeatRule = nil } }
        } label: {
            chip(current.map { TodoWords.repeatLabel($0) } ?? "Repeat", symbol: "repeat", set: current != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(current.map { "Repeats \(TodoWords.repeatLabel($0)). Change" } ?? "Repeat")
        .accessibilityIdentifier("tasks.new.repeat")
    }

    private var whoMenu: some View {
        Menu {
            Button { model.setWho(nil, alone: false) } label: {
                if model.helper == nil { Label("Just Me", systemImage: "checkmark") } else { Text("Just Me") }
            }
            Section("Work Together") {
                ForEach(model.bots, id: \.id) { bot in
                    Button { model.setWho(bot.id, alone: false) } label: {
                        if model.helper == bot.id, !model.alone { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                    }
                }
            }
            Section("Give to Bot") {
                ForEach(model.bots, id: \.id) { bot in
                    Button { model.setWho(bot.id, alone: true) } label: {
                        if model.helper == bot.id, model.alone { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let helper = model.helper {
                    HeadImage(raw: model.head(helper), profile: helper, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                } else {
                    Image(systemName: "person").imageScale(.small).foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
                }
                Text(model.whoLabel).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
            }
            .font(Font.hq(.footnote).weight(model.helper != nil ? .semibold : .regular))
            .foregroundStyle(model.helper != nil ? Color.hqTintText : Color.hqLabel)
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(Capsule().fill(model.helper != nil ? Color.hqTint.opacity(0.12) : Color.hqFill3))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Who: \(model.whoLabel). Change")
        .accessibilityIdentifier("tasks.new.who-menu")
    }
}
