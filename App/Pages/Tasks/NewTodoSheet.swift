// [tasks] New Task. Owner 2026-11-04 after the first try: picking Me / A Bot / Together "felt too complicated to toss the
// task in there", and a Together task with a bot did nothing ("I don't know if the bot's picking it up. I don't know if
// I'm supposed to message the bot"). So: the task, Due (Repeat for your own), and one "Ask a Bot to Help" row (No One by
// default). With a bot, Add opens its chat and asks it at once; it answers with one card of what it could take, so
// what it will do is settled there, in front of you. Steps and who-does-what are on the task's sheet afterwards.

import SwiftUI
import UIKit

@MainActor @Observable
final class NewTodoModel {
    let store: TasksStore
    let bots: [Bot]
    var title = ""
    /// The bot asked to help, or nil: your own task. A bot reads it at once (its chat opens with the question).
    var helper: String?
    var hasDue = false
    var due = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)).addingTimeInterval(9 * 3600)
    var hasTime = false
    var repeatRule: String?
    /// One of your lists (a task added while a list shows starts there), or nil.
    var section: String?
    var saving = false
    var failure: String?
    @ObservationIgnored var onCreated: ((TodoTask?) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?

    init(store: TasksStore, bots: [Bot], preferredBot: String?, section: String? = nil, dueDay: Date? = nil) {
        self.store = store
        self.section = section
        // [tasks-first] Added from Today, it is due today (a day, no time) until you say otherwise; added with a day
        // picked on Upcoming's week, it is due that day.
        if let dueDay {
            hasDue = true
            due = Calendar.current.startOfDay(for: dueDay).addingTimeInterval(9 * 3600)
        }
        self.bots = PagesNames.scopeChoices(bots)
        helper = preferredBot.flatMap { id in self.bots.contains { $0.id == id } ? id : nil }
    }

    func botName(_ id: String) -> String { PagesNames.botName(id, bots: bots) }
    func head(_ id: String) -> JSONValue? { PagesNames.head(id, bots: bots) }

    var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    func add() {
        guard canAdd else { return }
        saving = true
        failure = nil
        controller?.isModalInPresentation = true
        // With a bot it's a shared task with nothing split yet: the bot's first turn asks which parts it takes.
        var fields = TodoWire.newTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), who: helper == nil ? .me : .together,
                                      bot: helper, due: hasDue ? TodoDates.wire(due, hasTime: hasTime) : nil,
                                      repeatRule: helper == nil ? repeatRule : nil, prep: false)
        if let section { fields["section"] = .string(section) }
        Task {
            let made = await store.add(fields)
            saving = false
            controller?.isModalInPresentation = false
            if let made {
                PagesHaptics.success()
                let done = onCreated
                if let controller { controller.dismiss(animated: true) { done?(made) } } else { done?(made) }
            } else {
                PagesHaptics.error()
                // The gateway's own reason (it refused, read-only, …); the connection only when there's none.
                failure = store.addFailure ?? "Check your connection, then try again."
            }
        }
    }
}

enum NewTodoSheet {
    static func make(store: TasksStore, bots: [Bot], preferredBot: String?, section: String? = nil, dueDay: Date? = nil,
                     onCreated: @escaping (TodoTask?) -> Void) -> UIViewController {
        let model = NewTodoModel(store: store, bots: bots, preferredBot: preferredBot, section: section, dueDay: dueDay)
        model.onCreated = onCreated
        let host = NewTodoHost(model: model)
        let nav = ChatSheet.wrap(host, title: "New Task")
        host.installClose()
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

final class NewTodoHost: UIHostingController<HQScaledRoot<NewTodoView>> {
    let model: NewTodoModel
    private var addItem: UIBarButtonItem!

    init(model: NewTodoModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTodoView(model: model)))
        model.controller = self
        title = "New Task"
        addItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.model.add() })
        addItem.style = .prominent
        addItem.accessibilityIdentifier = "tasks.new.add"
        navigationItem.rightBarButtonItem = addItem
        updateAdd()
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (addItem?.isEnabled == true ? [.save("Add", #selector(addFromKeyboard))] : []) }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func addFromKeyboard() { model.add() }

    func installClose() {
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in
            guard let self, !self.model.saving else { return }
            self.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    private func observe() {
        withObservationTracking {
            _ = model.title
            _ = model.saving
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateAdd(); self?.observe() }
        }
    }

    private func updateAdd() {
        if model.saving {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = addItem
            addItem.setProminentEnabled(model.canAdd)
        }
    }
}

struct NewTodoView: View {
    @Bindable var model: NewTodoModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if let failure = model.failure {
                Section {
                    Label { Text("Couldn’t Add the Task. \(failure)") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(Color.hqRed)
                        .font(Font.hq(.subheadline))
                }
                .hqSheetRows()
            }
            Section {
                TextField("What needs doing?", text: $model.title, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    .accessibilityIdentifier("tasks.new.title")
                if !model.store.sections.isEmpty {
                    Picker("List", selection: Binding(get: { model.section }, set: { PagesHaptics.selection(); model.section = $0 })) {
                        Text("No List").tag(String?.none)
                        ForEach(model.store.sections) { section in Text(section.name).tag(Optional(section.id)) }
                    }
                    .hqMenuPicker()
                    .accessibilityIdentifier("tasks.new.section")
                }
            } header: { HQSectionLabel { Text("Task") } }
            .hqSheetRows()

            Section {
                Toggle("Due", isOn: Binding(get: { model.hasDue }, set: { PagesHaptics.selection(); model.hasDue = $0 }))
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("tasks.new.due")
                if model.hasDue {
                    HQDatePicker("Day", selection: $model.due, displayedComponents: .date)
                    Toggle("Time", isOn: Binding(get: { model.hasTime }, set: { PagesHaptics.selection(); model.hasTime = $0 }))
                        .tint(Color.hqTint)
                    if model.hasTime { HQDatePicker("At", selection: $model.due) }
                }
                if model.helper == nil {
                    Picker("Repeat", selection: Binding(get: { model.repeatRule }, set: { PagesHaptics.selection(); model.repeatRule = $0 })) {
                        Text(TodoWords.repeatLabel(nil)).tag(String?.none)
                        ForEach(TodoWords.repeatRules, id: \.self) { rule in Text(TodoWords.repeatLabel(rule)).tag(Optional(rule)) }
                    }
                    .hqMenuPicker()
                }
            } footer: { HQSectionFooter {
                // Your own task and one you share with a bot ring here; a day alone at 9:00 (TaskReminders).
                if model.hasDue { Text(TodoWords.alertNote(hasTime: model.hasTime)) }
            } }
            .hqSheetRows()

            Section {
                Picker(selection: Binding(get: { model.helper }, set: { PagesHaptics.selection(); model.helper = $0 })) {
                    Text("No One").tag(String?.none)
                    ForEach(model.bots, id: \.id) { bot in Text(bot.name).tag(Optional(bot.id)) }
                } label: {
                    HStack(spacing: 10) {
                        if let helper = model.helper {
                            HeadImage(raw: model.head(helper), profile: helper, size: 24)
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus").font(Font.hq(.body)).foregroundStyle(Color.hqTint)
                                .frame(width: 24, height: 24).accessibilityHidden(true)
                        }
                        Text("Ask a Bot to Help").foregroundStyle(Color.hqLabel)
                    }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("tasks.new.bot")
            } footer: { HQSectionFooter {
                if let helper = model.helper {
                    Text(TodoWords.newTaskHelpNote(model.botName(helper)))
                        .accessibilityIdentifier("tasks.new.help-note")
                } else {
                    Text("Just yours. You can ask a bot later from the task.")
                }
            } }
            .hqSheetRows()
        }
        .hqGroupedPage()
        .disabled(model.saving)
        .onAppear { focused = true }
    }
}
