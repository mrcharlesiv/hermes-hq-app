// Native task quick add. Parsing and saving stay in NewTodoModel; optional fields live under Details.

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
    var repeatRule: String?
    /// Picked on the priority button; nil: what the line says ("!high"), else none.
    var priority: Int?
    /// The list it starts in (the one on show).
    var section: String?
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
    var repeatNow: String? { who == .bot ? nil : (read.repeatRule ?? repeatRule) }
    var priorityNow: Int { fields ? (priority ?? read.priority ?? 0) : 0 }
    var who: TodoWho { helper == nil ? .me : (alone ? .bot : .together) }
    var listName: String? { section.flatMap { id in store.sections.first { $0.id == id }?.name } }

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

    func setWho(_ bot: String?, alone: Bool) {
        PagesHaptics.selection()
        helper = bot
        self.alone = bot != nil && alone
    }

    /// The line is empty again, for the next task: the list and who stay; the date goes back to the sheet's own day.
    private func startOver() {
        title = ""
        notes = ""
        manualDue = false
        literalTitle = false
        priority = nil
        repeatRule = nil
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
        // With a bot and you it's a shared task with nothing split yet: the bot's first turn asks which parts it takes.
        var fields = TodoWire.newTask(title: read.title.trimmingCharacters(in: .whitespacesAndNewlines), who: who, bot: helper,
                                      due: due.map { TodoDates.wire($0.date, hasTime: $0.hasTime) }, repeatRule: repeatNow, prep: false,
                                      notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        if who == .together, store.fieldsSupported, let rule = repeatNow { fields["repeat"] = .string(rule) }
        if store.fieldsSupported {
            if priorityNow > 0 { fields["priority"] = .number(Double(priorityNow)) }
            if !read.tags.isEmpty { fields["tags"] = .array(read.tags.map(JSONValue.string)) }
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
        let compact = UISheetPresentationController.Detent.custom(identifier: .init("tasks.new.compact")) { context in
            min(460, context.maximumDetentValue)
        }
        let nav = ChatSheet.wrap(host, title: "New Task", detents: [compact, .large()])
        nav.preferredContentSize = CGSize(width: 520, height: DeviceWord.isMac ? 540 : 460)
        // The title takes the keys on open, and compact plus the keyboard never fits a phone: the sheet rose to large and
        // the switch dropped the field's focus (keys up, then straight down). On a phone it opens at the height it types at.
        if !DeviceWord.isMac, UIDevice.current.userInterfaceIdiom == .phone, let sheet = nav.sheetPresentationController {
            sheet.selectedDetentIdentifier = .large
        }
        host.installClose()
        SheetEditGuard.install(on: nav)
        return nav
    }
}

/// A scrollable task sheet on mobile and a form dialog on Mac.
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
    @FocusState private var focus: Field?
    @State private var detailsOpen = false
    enum Field: Hashable { case title, notes }

    var body: some View {
        let read = model.read
        Form {
            Section {
                TextField("What needs to be done?", text: $model.title)
                    .focused($focus, equals: .title)
                    .submitLabel(.done).onSubmit { model.add() }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("tasks.new.title")
            } header: { HQSectionLabel { Text("Task title") } }
            Section {
                whoStrip
                if let helper = model.helper {
                    // Through the looks' strip (ThemeLintTests): the Desktop Look draws its own segments. setWho plays the tick.
                    HQSegmentedPicker("How to work", options: [("Work together", false), ("Give to \(model.botName(helper))", true)],
                                      selection: Binding(get: { model.alone }, set: { model.setWho(helper, alone: $0) }), ticks: false)
                    .accessibilityIdentifier("tasks.new.mode")
                }
            } header: { HQSectionLabel { Text("Who's involved") } }
            if read.title != model.title.trimmingCharacters(in: .whitespacesAndNewlines) || model.literalTitle {
                Section {
                    if model.literalTitle {
                        Text("Using your title exactly as typed.")
                    } else {
                        Text("Task name: \(read.title)")
                            .accessibilityLabel("Will be named \(read.title)")
                            .accessibilityIdentifier("tasks.new.read")
                        if let due = read.due { Text("Date: " + TodoWords.newTaskDue(due, hasTime: read.hasTime, now: Date())) }
                        if let rule = read.repeatRule { Text("Repeat: " + TodoWords.repeatLabel(rule)) }
                        if let priority = read.priority { Text("Priority: " + TodoViews.priorityWord(priority)) }
                        if !read.tags.isEmpty { Text("Tags: " + read.tags.map { "#" + $0 }.joined(separator: ", ")) }
                    }
                    Button(model.literalTitle ? "Read details from title" : "Keep title as typed") { model.literalTitle.toggle() }
                        .accessibilityIdentifier("tasks.new.literal")
                }.font(Font.hq(.footnote))
            }
            Section {
                Button { withAnimation(HQMotion.swiftUI(.snappy(duration: 0.2))) { detailsOpen.toggle() } } label: {
                    HStack {
                        Text("Details")
                        Spacer()
                        Image(systemName: detailsOpen ? "chevron.up" : "chevron.down").foregroundStyle(Color.hqLabel2)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("tasks.new.details")
                .accessibilityValue(detailsOpen ? "Expanded" : "Collapsed")
                if detailsOpen {
                    TextField("Notes", text: $model.notes, axis: .vertical)
                        .lineLimit(2...5).focused($focus, equals: .notes)
                        .accessibilityIdentifier("tasks.new.notes")
                    HStack { Text("Date"); Spacer(); dateChip(read) }
                    if model.fields { HStack { Text("Priority"); Spacer(); priorityChip } }
                    if !model.store.sections.isEmpty { HStack { Text("List"); Spacer(); listChip } }
                }
            } footer: { HQSectionFooter { Text("Notes, date, priority and list") } }
            if let failure = model.failure {
                Section { Text(failure).foregroundStyle(Color.hqRed).accessibilityIdentifier("tasks.new.failure") }
            } else if let helper = model.helper {
                Section { Text(model.alone ? "\(model.botName(helper))’s chat opens and it starts on the task right away." : TodoWords.newTaskHelpNote(model.botName(helper)))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("tasks.new.help-note") }
            } else if let added = model.added {
                Section { Label(added, systemImage: "checkmark").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("tasks.new.added") }
            }
        }
        .hqGroupedPage()
        .disabled(model.saving)
        .onAppear { focus = .title }
        .onChange(of: model.addedCount) { _, _ in focus = .title }
    }

    // MARK: The buttons

    private func chip(_ words: String?, symbol: String?, set: Bool, tint: Color? = nil) -> some View {
        QuickAddChip(words: words, symbol: symbol, set: set, tint: tint)
    }

    private func dateChip(_ read: TodoQuickRead) -> some View {
        let now = Date()
        let due = model.dueNow
        var words = due.map { TodoWords.newTaskDue($0.date, hasTime: $0.hasTime, now: now) }
        if let rule = model.repeatNow { words = [words, TodoWords.repeatLabel(rule)].compactMap { $0 }.joined(separator: " · ") }
        return Menu {
            Button("Today") { model.setDue(now, hasTime: false) }
            Button("Tomorrow") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…") { model.pickDate() }
            if due != nil { Button("No Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            chip(words ?? "Date", symbol: "calendar", set: due != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words.map { "Due \($0). Change" } ?? "Date")
        .accessibilityIdentifier("tasks.new.due")
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
            chip(level > 0 ? TodoViews.priorityWord(level) : nil, symbol: level > 0 ? "flag.fill" : "flag", set: level > 0,
                 tint: TodoPriorityLook.color(level))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level > 0 ? "\(TodoViews.priorityWord(level)) priority. Change" : "Priority")
        .accessibilityIdentifier("tasks.new.priority")
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
            chip(model.listName ?? "List", symbol: "tray", set: model.section != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.listName.map { "List: \($0). Change" } ?? "List")
        .accessibilityIdentifier("tasks.new.section")
    }

    @ViewBuilder private func whoPeople(column: Bool) -> some View {
        personButton(name: "You", id: nil, column: column)
        ForEach(model.bots, id: \.id) { bot in personButton(name: bot.name, id: bot.id, column: column) }
    }

    @ViewBuilder private var whoStrip: some View {
        if DeviceWord.isMac {
            // [new-task-who-mac] Owner 2026-11-21 (Mac screenshot): the sideways strip showed a grey scroller over the
            // names, and a click on a bot didn't pick it. On the Mac the faces wrap to more rows instead (FEEL-LIST #32):
            // no scroller, nothing out of reach, and each face is a plain button. Owner, same day, on Mac 1199: "The
            // bots don't line up properly" (each row started where its names' widths left it): the rows are a grid of
            // equal columns, each face centred over its name, a long name on two lines.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 12) { whoPeople(column: true) }
                .padding(.vertical, 4)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) { whoPeople(column: false) }.padding(.vertical, 4)
            }
            // `.hidden` still shows the scroller with a mouse attached (an iPad with a trackpad); `.never` hides it.
            .scrollIndicators(.never)
        }
    }

    /// `column`: a cell of the Mac's grid, filling its column with the name under the face on up to two lines.
    private func personButton(name: String, id: String?, column: Bool = false) -> some View {
        let selected = model.helper == id
        return Button { model.setWho(id, alone: false) } label: {
            VStack(spacing: 5) {
                Group {
                    if let id {
                        HeadImage(raw: model.head(id), profile: id, size: 40).frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable().frame(width: 40, height: 40).foregroundStyle(Color.hqLabel3)
                    }
                }
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.hqTint : .clear, lineWidth: 2))
                Text(name).font(Font.hq(.caption)).lineLimit(column ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Color.hqTintText : Color.hqLabel2)
            }.frame(minWidth: 52, maxWidth: column ? .infinity : nil, minHeight: 60, alignment: .top)
            .contentShape(Rectangle())   // the whole face and name take the click, not only their drawn pixels
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tasks.new.person.\(id ?? "you")")
    }
}
