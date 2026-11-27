// Best-of-both-worlds New Task sheet: roomy native sheet with Title + Notes directly visible,
// live natural-language parsing, a clean wrapping grid of one-tap task chips (Date, List, Priority,
// Tags, Goal, Repeat, Start Date), and the visual face-avatar Who's Involved strip (zero huge menus).

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
    /// Picked via the tappable Tag Picker; merged with parsed #tags until edited explicitly.
    var tags: [String] = []
    var manualTags = false
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
    var tagsNow: [String] {
        guard fields else { return [] }
        if manualTags { return tags }
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags + read.tags where seen.insert(tag.lowercased()).inserted && out.count < 10 {
            out.append(tag)
        }
        return out
    }
    var who: TodoWho { helper == nil ? .me : (alone ? .bot : .together) }
    var listName: String? { section.flatMap { id in store.sections.first { $0.id == id }?.name } }
    var goalName: String? { goal.flatMap { id in store.goal(id)?.title }.flatMap { $0.isEmpty ? "Untitled Goal" : $0 } }

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

    func setTags(_ picked: [String]) {
        PagesHaptics.selection()
        manualTags = true
        tags = picked
    }

    func pickTags() {
        guard let controller else { return }
        PagesHaptics.selection()
        let picker = TaskTagPickerSheet.make(selected: tagsNow, existing: TodoViews.allTags(in: store.tasks)) { [weak self] picked in
            self?.setTags(picked)
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
        tags = []
        manualTags = false
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
            let finalTags = tagsNow
            if !finalTags.isEmpty { fields["tags"] = .array(finalTags.map(JSONValue.string)) }
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
        let host = NewTodoHost(model: model)
        let roomy = UISheetPresentationController.Detent.custom(identifier: .init("tasks.new.roomy")) { context in
            min(560, context.maximumDetentValue)
        }
        let nav = ChatSheet.wrap(host, title: "New Task", detents: [roomy, .large()])
        nav.preferredContentSize = CGSize(width: 540, height: DeviceWord.isMac ? 600 : 560)
        // Open at the full typing height on iPhone so the title keeps keyboard focus and everything breathes.
        if !DeviceWord.isMac, UIDevice.current.userInterfaceIdiom == .phone, let sheet = nav.sheetPresentationController {
            sheet.selectedDetentIdentifier = .large
        }
        host.installClose()
        SheetEditGuard.install(on: nav)
        return nav
    }
}

/// A scrollable task sheet on mobile and a roomy form dialog on Mac.
final class NewTodoHost: UIHostingController<HQScaledRoot<NewTodoView>>, EditingPage {
    let model: NewTodoModel
    private var addItem: UIBarButtonItem!

    init(model: NewTodoModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTodoView(model: model)))
        model.controller = self
        rootView = HQScaledRoot(NewTodoView(model: model))
        title = "New Task"
        addItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.model.add() })
        addItem.style = .prominent
        addItem.accessibilityIdentifier = "tasks.new.add"
        navigationItem.rightBarButtonItem = addItem
        addItem.setProminentEnabled(model.canAdd)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "tasks.new.sheet"
        view.backgroundColor = HQPalette.sheetPage
        observeForm()
    }

    func installClose() {
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in self?.closeAsking() })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    // Any typed draft requires confirmation before dismissing the sheet.
    var hasChanges: Bool {
        !model.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isSaving: Bool { model.saving }

    private func observeForm() {
        withObservationTracking {
            _ = model.title
            _ = model.notes
            _ = model.saving
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.refreshLock(); self?.observeForm() }
        }
        refreshLock()
    }

    private func refreshLock() {
        if isSaving {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = addItem
            addItem.setProminentEnabled(model.canAdd)
        }
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        if let navigation = navigationController {
            EditingGuard.refreshLock(navigation)
            if isSaving { EditingGuard.dropQuestion() }
        }
    }

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

/// [goals] What a quick add's sheet is (New Goal's): as tall as its content, over the keyboard, on one
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
            let sheetRadius = HQShape.desktopRadius(.sheet)
            sheet.preferredCornerRadius = Theme.isDesktop ? (sheetRadius == 0 ? 0 : min(26, sheetRadius + 2)) : nil
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
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(tint ?? (set ? Color.hqTintText : Color.hqLabel2)) }
            if let words { Text(words).lineLimit(1) }
        }
        .font(Font.hq(.footnote).weight(set && !DeviceWord.isMac ? .semibold : .regular))   // [type] Mac: the tint shows it is set
        .foregroundStyle(set ? Color.hqTintText : Color.hqLabel)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Capsule().fill(set ? Color.hqTint.opacity(0.14) : Color.hqFill3))
        .overlay {
            if set { Capsule().strokeBorder(Color.hqTint.opacity(0.32), lineWidth: HQShape.hairline) }
        }
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
    @FocusState private var focus: Field?
    enum Field: Hashable { case title, notes }

    private var trimmedTitle: String { model.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let read = model.read
        let parsedDifferent = !trimmedTitle.isEmpty && (read.title != trimmedTitle || model.literalTitle)
        Form {
            // Card 1: Title, inline natural-language parsed preview, and directly visible Notes.
            Section {
                VStack(alignment: .leading, spacing: 8) {
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

                    if parsedDifferent {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(model.literalTitle ? "Using your title exactly as typed" : parsedSummary(read))
                                .font(Font.hq(.footnote))
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(2)
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
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)

                TextField("Notes (optional)", text: $model.notes, axis: .vertical)
                    .lineLimit(2...5)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .focused($focus, equals: .notes)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("tasks.new.notes")
            }
            .hqSheetRows()

            // Card 2: Who's involved (visual face-avatar strip right under Title/Notes — one tap above the keyboard, zero huge menu).
            if !model.bots.isEmpty {
                Section {
                    whoStrip
                    if let helper = model.helper {
                        // Through the looks' strip (ThemeLintTests): the Desktop Look draws its own segments. setWho plays the tick.
                        HQSegmentedPicker("How to work", options: [("Work together", false), ("Give to \(model.botName(helper))", true)],
                                          selection: Binding(get: { model.alone }, set: { model.setWho(helper, alone: $0) }), ticks: false)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("tasks.new.mode")
                    }
                } header: {
                    HQSectionLabel { Text("Who's involved") }
                } footer: {
                    if let helper = model.helper {
                        HQSectionFooter {
                            Text(model.alone ? "\(model.botName(helper))’s chat opens and it starts on the task right away." : TodoWords.newTaskHelpNote(model.botName(helper)))
                                .accessibilityIdentifier("tasks.new.help-note")
                        }
                    }
                }
                .hqSheetRows()
            }

            // Card 3: Schedule (time-based fields grouped cleanly as native rows).
            Section {
                dateRow(read)
                if model.fields { startsRow }
                if model.who != .bot && (model.who == .me || model.fields) { repeatRow }
            } header: {
                HQSectionLabel { Text("Schedule") }
            }
            .hqSheetRows()

            // Card 4: Organize (filing and classification fields grouped cleanly as native rows).
            if !model.store.sections.isEmpty || model.fields || !model.activeGoals.isEmpty {
                Section {
                    if !model.store.sections.isEmpty { listRow }
                    if model.fields { priorityRow }
                    if model.fields { tagsRow }
                    if !model.activeGoals.isEmpty { goalRow }
                } header: {
                    HQSectionLabel { Text("Organize") }
                }
                .hqSheetRows()
            }

            if let failure = model.failure {
                Section {
                    Text(failure)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                        .accessibilityIdentifier("tasks.new.failure")
                }
                .hqSheetRows()
            } else if let added = model.added {
                Section {
                    Label(added, systemImage: "checkmark")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("tasks.new.added")
                }
                .hqSheetRows()
            }
        }
        .hqGroupedPage()
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.saving)
        .onAppear { focus = .title }
        .onChange(of: model.addedCount) { _, _ in focus = .title }
    }

    private func parsedSummary(_ read: TodoQuickRead) -> String {
        var parts = ["→ “\(read.title)”"]
        if let due = read.due { parts.append(TodoWords.newTaskDue(due, hasTime: read.hasTime, now: Date())) }
        if let rule = read.repeatRule { parts.append(TodoWords.repeatLabel(rule)) }
        if let priority = read.priority { parts.append(TodoViews.priorityWord(priority)) }
        if !read.tags.isEmpty { parts.append(read.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Structured form rows

    private func formRowLabel(title: String, symbol: String, symbolColor: Color? = nil, value: String, set: Bool, chevron: String = "chevron.up.chevron.down") -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(Font.hq(.body))
                .foregroundStyle(symbolColor ?? (set ? Color.hqTint : Color.hqLabel2))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel)
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Text(value)
                    .font(Font.hq(.subheadline).weight(set ? .medium : .regular))
                    .foregroundStyle(set ? Color.hqTintText : Color.hqLabel2)
                    .lineLimit(1)
                Image(systemName: chevron)
                    .font(Font.hq(.caption2).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func dateRow(_ read: TodoQuickRead) -> some View {
        let now = Date()
        let due = model.dueNow
        let words = due.map { TodoWords.newTaskDue($0.date, hasTime: $0.hasTime, now: now) }
        return Menu {
            Button("Today", systemImage: "sun.max") { model.setDue(now, hasTime: false) }
            Button("Tomorrow", systemImage: "sunrise") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week", systemImage: "calendar") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…", systemImage: "calendar.badge.plus") { model.pickDate() }
            if due != nil { Button("No Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            formRowLabel(title: "Due", symbol: "calendar", value: words ?? "None", set: due != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "Due \($0). Change" } ?? "Date")
        .accessibilityIdentifier("tasks.new.due")
    }

    private var startsRow: some View {
        let now = Date()
        let words = model.starts.map { TodoViews.soon($0, now: now) }
        return Menu {
            Button("Today", systemImage: "sun.max") { model.setStarts(now) }
            Button("Tomorrow", systemImage: "sunrise") { model.setStarts(Calendar.current.date(byAdding: .day, value: 1, to: now)) }
            Button("Next Week", systemImage: "calendar") { model.setStarts(Calendar.current.date(byAdding: .day, value: 7, to: now)) }
            Button("Choose Date…", systemImage: "calendar.badge.clock") { model.pickStarts() }
            if model.starts != nil { Button("No Start Date", role: .destructive) { model.setStarts(nil) } }
        } label: {
            formRowLabel(title: "Start Date", symbol: "calendar.badge.clock", value: words ?? "None", set: model.starts != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "Starts \($0). Change" } ?? "Start Date")
        .accessibilityIdentifier("tasks.new.starts")
    }

    private var repeatRow: some View {
        let current = model.repeatNow
        return Menu {
            ForEach(TodoWords.repeatRules, id: \.self) { rule in
                Button { PagesHaptics.selection(); model.repeatRule = rule } label: {
                    if current == rule { Label(TodoWords.repeatLabel(rule), systemImage: "checkmark") } else { Text(TodoWords.repeatLabel(rule)) }
                }
            }
            if current != nil { Button("Don’t Repeat", role: .destructive) { PagesHaptics.selection(); model.repeatRule = nil } }
        } label: {
            formRowLabel(title: "Repeat", symbol: "repeat", value: current.map { TodoWords.repeatLabel($0) } ?? "Never", set: current != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(current.map { "Repeats \(TodoWords.repeatLabel($0)). Change" } ?? "Repeat")
        .accessibilityIdentifier("tasks.new.repeat")
    }

    private var listRow: some View {
        let icon = model.section.flatMap { id in model.store.sections.first { $0.id == id }?.icon } ?? "tray"
        return Menu {
            Button { PagesHaptics.selection(); model.section = nil } label: {
                if model.section == nil { Label("No List", systemImage: "checkmark") } else { Text("No List") }
            }
            ForEach(model.store.sections) { list in
                Button { PagesHaptics.selection(); model.section = list.id } label: {
                    if model.section == list.id { Label(list.name, systemImage: "checkmark") } else { Text(list.name) }
                }
            }
        } label: {
            formRowLabel(title: "List", symbol: icon, value: model.listName ?? "Inbox", set: model.section != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.listName.map { "List: \($0). Change" } ?? "List")
        .accessibilityIdentifier("tasks.new.section")
    }

    private var priorityRow: some View {
        let level = model.priorityNow
        return Menu {
            ForEach([1, 2, 3], id: \.self) { value in
                Button { PagesHaptics.selection(); model.priority = value } label: {
                    if level == value { Label(TodoViews.priorityWord(value), systemImage: "checkmark") } else { Text(TodoViews.priorityWord(value)) }
                }
            }
            if level > 0 { Button("No Priority", role: .destructive) { PagesHaptics.selection(); model.priority = 0 } }
        } label: {
            formRowLabel(title: "Priority", symbol: level > 0 ? "flag.fill" : "flag",
                         symbolColor: level > 0 ? TodoPriorityLook.color(level) : nil,
                         value: level > 0 ? TodoViews.priorityWord(level) : "None", set: level > 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level > 0 ? "\(TodoViews.priorityWord(level)) priority. Change" : "Priority")
        .accessibilityIdentifier("tasks.new.priority")
    }

    private var tagsRow: some View {
        let active = model.tagsNow
        let words: String = {
            guard !active.isEmpty else { return "None" }
            if active.count <= 2 { return active.joined(separator: ", ") }
            return "\(active[0]), \(active[1]) +\(active.count - 2)"
        }()
        return Button { model.pickTags() } label: {
            formRowLabel(title: "Tags", symbol: "tag", value: words, set: !active.isEmpty, chevron: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active.isEmpty ? "Tags" : "Tags: \(active.joined(separator: ", ")). Change")
        .accessibilityIdentifier("tasks.new.tags")
    }

    private var goalRow: some View {
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
            formRowLabel(title: "Goal", symbol: "smallcircle.filled.circle", value: model.goalName ?? "None", set: model.goal != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.goalName.map { "Goal: \($0). Change" } ?? "Goal")
        .accessibilityIdentifier("tasks.new.goal")
    }

    // MARK: Who's involved (visual face strip)

    @ViewBuilder private func whoPeople(column: Bool) -> some View {
        personButton(name: "You", id: nil, column: column)
        ForEach(model.bots, id: \.id) { bot in personButton(name: bot.name, id: bot.id, column: column) }
    }

    @ViewBuilder private var whoStrip: some View {
        if DeviceWord.isMac {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 12) { whoPeople(column: true) }
                .padding(.vertical, 6)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) { whoPeople(column: false) }.padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
    }

    /// `column`: a cell of the Mac's grid, filling its column with the name under the face on up to two lines.
    private func personButton(name: String, id: String?, column: Bool = false) -> some View {
        let selected = model.helper == id
        return Button { model.setWho(id, alone: false) } label: {
            VStack(spacing: 6) {
                Group {
                    if let id {
                        HeadImage(raw: model.head(id), profile: id, size: 42).frame(width: 42, height: 42)
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable().frame(width: 42, height: 42).foregroundStyle(Color.hqLabel3)
                    }
                }
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.hqTint : .clear, lineWidth: 2))
                Text(name).font(Font.hq(.caption).weight(selected ? .semibold : .regular)).lineLimit(column ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Color.hqTintText : Color.hqLabel2)
            }.frame(minWidth: 54, maxWidth: column ? .infinity : nil, minHeight: 64, alignment: .top)
            .contentShape(Rectangle())   // the whole face and name take the click, not only their drawn pixels
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tasks.new.person.\(id ?? "you")")
    }
}
