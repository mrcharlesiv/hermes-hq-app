// [tasks-first] Step 4 (owner 2026-11-12, mockup 5-new-task: "New Task: type it and go … the quick add every task app
// has. Type one line; the date is read from your words; four small buttons cover the rest"): New Task is a small sheet
// over the keyboard, with the list still behind it. One line for the task (`TodoQuickParse` reads its date, time,
// repeat, #tags and priority as you type), a line for notes, and one row of buttons: date, priority, list, who, and
// Add. It stays open after a task of your own, for the next one; with a bot picked it closes and the task opens with
// that bot's chat, as before. The same + as always: no second way to add.

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
    /// A date picked by hand (the date button): the line's own date words stay in the name then.
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
    @ObservationIgnored var onCreated: ((TodoTask?) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?
    @ObservationIgnored private var addedWork: DispatchWorkItem?
    /// The day the sheet opened on (Today's +, a day picked on Upcoming): every task added here starts there.
    @ObservationIgnored private let startDay: Date?

    init(store: TasksStore, bots: [Bot], preferredBot: String?, section: String? = nil, dueDay: Date? = nil) {
        self.store = store
        self.section = section
        startDay = dueDay
        self.bots = PagesNames.scopeChoices(bots)
        helper = preferredBot.flatMap { id in self.bots.contains { $0.id == id } ? id : nil }
        startOver()
    }

    func botName(_ id: String) -> String { PagesNames.botName(id, bots: bots) }
    func head(_ id: String) -> JSONValue? { PagesNames.head(id, bots: bots) }
    var fields: Bool { store.fieldsSupported }

    /// What the line says, read as it is typed.
    var read: TodoQuickRead { TodoQuickParse.read(title, now: Date(), dates: !manualDue) }

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

/// The quick add: a sheet as tall as its content, over the keyboard, with the list dimmed behind it. A tap outside (or
/// a pull down, or Escape) closes it.
final class NewTodoHost: UIHostingController<HQScaledRoot<NewTodoView>> {
    let model: NewTodoModel
    private var fitted: CGFloat = 150

    init(model: NewTodoModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTodoView(model: model)))
        model.controller = self
        rootView = HQScaledRoot(NewTodoView(model: model, onHeight: { [weak self] in self?.fit($0) }))
        modalPresentationStyle = DeviceWord.isMac ? .formSheet : .pageSheet
        preferredContentSize = CGSize(width: 520, height: fitted)
        view.backgroundColor = HQPalette.groupedCard
        view.accessibilityIdentifier = "tasks.new.sheet"
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("tasks.new")) { [weak self] _ in self?.fitted ?? 150 }]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.preferredCornerRadius = Theme.isDesktop ? DesktopRows.radius + 6 : nil
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The content's height changed (a second line of notes, the bot's note): the sheet follows.
    private func fit(_ height: CGFloat) {
        let next = max(110, height.rounded(.up))
        guard abs(next - fitted) > 0.5 else { return }
        fitted = next
        preferredContentSize = CGSize(width: 520, height: next)
        guard let sheet = sheetPresentationController else { return }
        if view.window == nil || HQMotion.reduced {
            sheet.invalidateDetents()
        } else {
            sheet.animateChanges { sheet.invalidateDetents() }
        }
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
    @objc private func closeFromKeyboard() { if !model.saving { dismiss(animated: true) } }
}

struct NewTodoView: View {
    @Bindable var model: NewTodoModel
    var onHeight: (CGFloat) -> Void = { _ in }
    @FocusState private var focus: Field?
    enum Field: Hashable { case title, notes }

    var body: some View {
        let read = model.read
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("New task", text: $model.title, axis: .vertical)
                    .lineLimit(1...3)
                    .font(Font.hq(.body).weight(.medium))
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
                    // Return adds (the line is one task); a pasted line break stays out of the name.
                    .onChange(of: model.title) { _, text in
                        guard text.contains("\n") else { return }
                        model.title = text.replacingOccurrences(of: "\n", with: " ")
                        model.add()
                    }
                    .accessibilityIdentifier("tasks.new.title")
                if DeviceWord.isMac {
                    Button { model.controller?.dismiss(animated: true) } label: {
                        Image(systemName: "xmark").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.saving)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("sheet.close")
                }
            }
            .padding(.top, 16)
            // What the line was read as, while it differs from what you typed: the name it will have.
            if model.dueNow != nil || read.repeatRule != nil || !read.tags.isEmpty, read.title != model.title.trimmingCharacters(in: .whitespaces),
               !read.title.isEmpty {
                Text("“\(read.title)”")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .padding(.top, 3)
                    .accessibilityLabel("Will be named \(read.title)")
                    .accessibilityIdentifier("tasks.new.read")
            }
            TextField("Notes", text: $model.notes, axis: .vertical)
                .lineLimit(1...3)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .focused($focus, equals: .notes)
                .padding(.top, 8)
                .accessibilityIdentifier("tasks.new.notes")
            if let failure = model.failure {
                Text(failure).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    .accessibilityIdentifier("tasks.new.failure")
            } else if let helper = model.helper {
                Text(model.alone ? "\(model.botName(helper))’s chat opens and it starts on the task right away."
                                 : TodoWords.newTaskHelpNote(model.botName(helper)))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    .accessibilityIdentifier("tasks.new.help-note")
            } else if let added = model.added {
                Label(added, systemImage: "checkmark")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1).padding(.top, 6)
                    .accessibilityIdentifier("tasks.new.added")
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        dateChip(read)
                        if model.fields { priorityChip }
                        if !model.store.sections.isEmpty { listChip }
                        whoChip
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                Button { model.add() } label: {
                    Group {
                        if model.saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(Font.hq(.title).weight(.regular))
                                .foregroundStyle(model.canAdd ? Color.hqTint : Color.hqLabel3)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canAdd)
                .accessibilityLabel("Add")
                .accessibilityIdentifier("tasks.new.add")
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focus = .title }
    }

    // MARK: The buttons

    private func chip(_ words: String?, symbol: String?, set: Bool, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(tint ?? (set ? Color.hqTintText : Color.hqLabel2)) }
            if let words { Text(words).lineLimit(1) }
        }
        .font(Font.hq(.footnote).weight(set ? .semibold : .regular))
        .foregroundStyle(set ? Color.hqTintText : Color.hqLabel2)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Capsule().fill(set ? Color.hqTint.opacity(0.12) : Color.hqFill3))
        .contentShape(Capsule())
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

    private var whoChip: some View {
        let words = model.helper.map { model.alone ? model.botName($0) : "Me & \(model.botName($0))" } ?? "Me"
        return Menu {
            Button { model.setWho(nil, alone: false) } label: {
                if model.helper == nil { Label("Just Me", systemImage: "checkmark") } else { Text("Just Me") }
            }
            if !model.bots.isEmpty {
                Section("With Me") {
                    ForEach(model.bots, id: \.id) { bot in
                        Button { model.setWho(bot.id, alone: false) } label: {
                            if model.helper == bot.id, !model.alone { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                        }
                    }
                }
                Section("By Itself") {
                    ForEach(model.bots, id: \.id) { bot in
                        Button { model.setWho(bot.id, alone: true) } label: {
                            if model.helper == bot.id, model.alone { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let helper = model.helper {
                    HeadImage(raw: model.head(helper), profile: helper, size: 16).frame(width: 16, height: 16).accessibilityHidden(true)
                } else {
                    Image(systemName: "person").imageScale(.small)
                }
                Text(words).lineLimit(1)
            }
            .font(Font.hq(.footnote).weight(model.helper != nil ? .semibold : .regular))
            .foregroundStyle(model.helper != nil ? Color.hqTintText : Color.hqLabel2)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Capsule().fill(model.helper != nil ? Color.hqTint.opacity(0.12) : Color.hqFill3))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Who: \(words). Change")
        .accessibilityIdentifier("tasks.new.bot")
    }
}
