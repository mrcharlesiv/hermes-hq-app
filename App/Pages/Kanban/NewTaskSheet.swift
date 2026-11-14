// New Task (docs/spec/1x-pages.md §4.7): a form sheet — what needs doing and details, who does it (the resolved
// default first, every bot, then No One Yet), Start In (Triage | Ready) and More Options (priority, skills, goal mode).
// Add sends only what was given, on the board Add was tapped on; a failure keeps the sheet open with the reason.

import SwiftUI
import UIKit

@MainActor @Observable
final class NewTaskModel {
    let store: KanbanStore
    @ObservationIgnored weak var services: PagesServices?
    var title = ""
    var details = ""
    var who: String
    var start: String
    var more = false
    var priority = 0
    var skills = ""
    var goal = false
    var saving = false
    var failure: String?
    @ObservationIgnored var onCreated: ((String?) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?

    init(store: KanbanStore, services: PagesServices, startIn: String) {
        self.store = store
        self.services = services
        who = store.resolvedDefault
        start = startIn
    }

    /// The resolved default first, then every bot, then "" (No One Yet).
    var people: [String] {
        var seen = Set<String>()
        return ([store.resolvedDefault] + store.profiles.map(\.name)).filter { !$0.isEmpty && seen.insert($0).inserted } + [""]
    }

    func botName(_ name: String) -> String { PagesNames.botName(name, bots: services?.bots ?? []) }
    func head(_ name: String) -> JSONValue? { PagesNames.head(name, bots: services?.bots ?? []) }

    func add() {
        guard !title.pgTrim.isEmpty, !saving else { return }
        saving = true
        failure = nil
        controller?.isModalInPresentation = true
        let skillList = skills.split(separator: ",").map { String($0).pgTrim }.filter { !$0.isEmpty }
        Task {
            do {
                let warning = try await store.create(title: title, body: details, assignee: who.isEmpty ? nil : who,
                                                     priority: priority, skills: skillList, start: start, goalMode: goal)
                PagesHaptics.success()
                saving = false
                controller?.dismiss(animated: true)
                onCreated?(warning)
            } catch {
                PagesHaptics.error()
                saving = false
                controller?.isModalInPresentation = false
                failure = PagesREST.reason(error)
            }
        }
    }

    /// The task sheet's Other Number… prompt: any priority, not only the menu's.
    func askPriority() {
        guard let controller else { return }
        let alert = UIAlertController(title: "Priority", message: "Higher numbers are picked up first.", preferredStyle: .alert)
        alert.addTextField { [priority] field in
            field.text = String(priority)
            field.keyboardType = .numberPad
            field.placeholder = "0"
            field.addNumberPadDone()   // [diagnostics]
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let set = UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.pgTrim ?? ""
            if let value = Int(text), value >= 0 { PagesHaptics.selection(); self?.priority = value }
        }
        alert.addAction(set)
        alert.preferredAction = set   // [mac] audit 2026-11-02 #17: Return sets it, as every other one-field prompt
        controller.present(alert, animated: true)
    }
}

enum NewTaskSheet {
    static func make(store: KanbanStore, services: PagesServices, startIn: String, onCreated: @escaping (String?) -> Void) -> UIViewController {
        let model = NewTaskModel(store: store, services: services, startIn: startIn)
        model.onCreated = onCreated
        let host = NewTaskHostController(model: model)
        // Verify round 2: the one sheet bar every other sheet has (✕ leading, inline title, no grabber, opaque page).
        let nav = ChatSheet.wrap(host, title: "New Task")
        host.installClose()
        SheetEditGuard.install(on: nav)   // [Mac UI check 2026-11-13] typed words ask before Cancel, Escape or ⌘W drop them
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        return nav
    }
}

final class NewTaskHostController: UIHostingController<HQScaledRoot<NewTaskView>>, EditingPage {
    let model: NewTaskModel
    private var addItem: UIBarButtonItem!
    private var observation: Task<Void, Never>?

    init(model: NewTaskModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(NewTaskView(model: model)))
        model.controller = self
        title = "New Task"
        addItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.model.add() })
        addItem.style = .prominent
        addItem.accessibilityIdentifier = "kanban.new.add"
        navigationItem.rightBarButtonItem = addItem
        updateAdd()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (addItem?.isEnabled == true ? [.save("Add", #selector(addFromKeyboard))] : []) }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func addFromKeyboard() { model.add() }

    /// [Mac UI check 2026-11-13] Words typed in (the task, its details, skills) are asked about before they go.
    var hasChanges: Bool { !(model.title + model.details + model.skills).pgTrim.isEmpty }
    var isSaving: Bool { model.saving }

    /// ✕ (after `ChatSheet.wrap`): closes, except while the task is being saved; typed words ask first.
    func installClose() {
        // [mac] Stress test 2026-10-28 #55: a form beside Add closes with Cancel on the leading edge on the Mac.
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in
            guard let self, !self.model.saving else { return }
            self.view.endEditing(true)
            self.confirmLeaving { [weak self] in self?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "kanban.new"
        observe()
    }

    /// Add is enabled once the title has text; a spinner replaces it while saving.
    private func observe() {
        withObservationTracking {
            _ = model.title
            _ = model.details
            _ = model.skills
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
            addItem.setProminentEnabled(!model.title.pgTrim.isEmpty)
        }
        if let navigation = navigationController { EditingGuard.refreshLock(navigation) }
    }
}

struct NewTaskView: View {
    @Bindable var model: NewTaskModel
    @FocusState private var focus: Field?
    enum Field { case title, details }

    var body: some View {
        Form {
            if let failure = model.failure {
                Section {
                    Label { Text("Couldn’t Add the Task. \(failure)") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(Color.hqRed)
                        .font(Font.hq(.subheadline))
                        .accessibilityIdentifier("kanban.new.failure")
                }
            }
            Section {
                TextField("What needs doing?", text: $model.title)
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .details }
                    .accessibilityIdentifier("kanban.new.title")
                TextField("Details (optional)", text: $model.details, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focus, equals: .details)
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(model.people, id: \.self) { name in
                            Button {
                                if model.who != name { PagesHaptics.selection() }
                                model.who = name
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if name.isEmpty {
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .strokeBorder(Color.hqLabel3, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                        } else {
                                            HeadImage(raw: model.head(name), profile: name, size: HQFont.scaled(44))
                                        }
                                    }
                                    .frame(width: HQFont.scaled(44), height: HQFont.scaled(44))
                                    .padding(3)
                                    Text(name.isEmpty ? "No One Yet" : model.botName(name))
                                        .font(Font.hq(.caption))
                                        .foregroundStyle(model.who == name ? Color.hqTintText : Color.hqLabel2)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: HQFont.scaled(76))   // [ui-sizing] × UI Scale, as its caption: names broke mid-word at 150 %
                                .padding(.vertical, 4)
                                // The chosen one sits on a soft tinted card, head and name together: a ring drawn
                                // around the head was a rounded square that fit square heads and not round ones.
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(model.who == name ? Color.hqTint.opacity(0.14) : .clear))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name.isEmpty ? "No One Yet" : model.botName(name))
                            .accessibilityAddTraits(model.who == name ? .isSelected : [])
                            .accessibilityIdentifier(name.isEmpty ? "kanban.new.nobody" : "kanban.new.who.\(name)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            } header: { HQSectionLabel { Text("Who Does It") } } footer: { HQSectionFooter {
                if model.who.isEmpty { Text("The task waits until you assign it.") }
            } }
            Section {
                HQSegmentedPicker("Start In", options: [("Triage", "triage"), ("Ready", "ready")],
                                  selection: Binding(get: { model.start }, set: { PagesHaptics.selection(); model.start = $0 }), ticks: false)   // [desktoplook3]
                .accessibilityIdentifier("kanban.new.start")
            } header: { HQSectionLabel { Text("Start In") } } footer: { HQSectionFooter { Text(KanbanModel.statusHelp[model.start] ?? "") }}
            Section {
                DisclosureGroup("More Options", isExpanded: $model.more) {
                    // The task sheet's priority choices (a bare "0" field gave no hint which way goes first), and a
                    // line under each option saying what it does. Other Number… keeps any priority settable.
                    VStack(alignment: .leading, spacing: 4) {
                        Menu {
                            Picker("Priority", selection: Binding(get: { model.priority }, set: { PagesHaptics.selection(); model.priority = $0 })) {
                                ForEach(Array(Set([0, 1, 2, 3, 5, 10, model.priority])).sorted(), id: \.self) { value in
                                    Text(value == 0 ? "None" : String(value)).tag(value)
                                }
                            }
                            Button("Other Number…") { model.askPriority() }
                        } label: {
                            LabeledContent("Priority") {
                                HStack(spacing: 4) {
                                    Text(model.priority == 0 ? "None" : String(model.priority)).foregroundStyle(Color.hqLabel2)
                                    Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel3)
                                }
                            }
                            .foregroundStyle(Color.hqLabel)
                        }
                        .accessibilityIdentifier("kanban.new.priority")
                        Text("Higher goes first.").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Skills") {
                            TextField("translation, github", text: $model.skills)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Skills the bot loads for this task, separated by commas.")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Goal Mode", isOn: Binding(get: { model.goal }, set: { PagesHaptics.selection(); model.goal = $0 }))
                        Text("The bot keeps working until a judge agrees the task is done.")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Text("The task uses this board’s workspace and the bot’s own model. Change those on the desktop board.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .disabled(model.saving)
        .onAppear { focus = .title }
    }
}
