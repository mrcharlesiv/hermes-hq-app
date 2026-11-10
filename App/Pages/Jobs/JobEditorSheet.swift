// [jobs] New Job / Edit Job (docs/spec/3x-jobs.md §4.3-§4.6): one large sheet for both, the bar every native sheet has
// (✕ leading, the title, a prominent Create / Save that becomes a spinner while the gateway answers), a discard
// question for a changed form, and the pushed pickers (the model, and the blueprints when there are many). The form
// itself is `JobEditorView` (JobEditorView.swift); what it holds and sends is `JobEditorModel` (HermesKit).

import SwiftUI
import UIKit

@MainActor
enum JobEditorSheet {
    nonisolated(unsafe) private static var guardKey: UInt8 = 0

    static func make(model: JobEditorModel, head: @escaping (String) -> JSONValue? = { _ in nil },
                     onDone: @escaping (JobEditorModel.Outcome) -> Void) -> UINavigationController {
        let host = JobEditorHostController(model: model, head: head, onDone: onDone)
        let navigation = ChatSheet.wrap(host, title: model.title, detents: [.large()])
        // On glass at full height too, its pieces glass on it (owner 2026-10-31); the Desktop Look stays solid.
        navigation.sheetPresentationController?.hqGlassPage(everyHeight: true)
        host.installClose()
        // A changed form asks before a swipe down closes it (D-J5).
        let guardian = SheetEditGuard(navigation: navigation)
        navigation.presentationController?.delegate = guardian
        objc_setAssociatedObject(navigation, &guardKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return navigation
    }
}

final class JobEditorHostController: UIHostingController<HQScaledRoot<JobEditorView>>, EditingPage {
    let model: JobEditorModel
    private let onDone: (JobEditorModel.Outcome) -> Void
    private var saveItem: UIBarButtonItem!
    private var loaded = false

    init(model: JobEditorModel, head: @escaping (String) -> JSONValue?, onDone: @escaping (JobEditorModel.Outcome) -> Void) {
        self.model = model
        self.onDone = onDone
        super.init(rootView: HQScaledRoot(JobEditorView(model: model, pickModel: {}, pickBlueprint: {})))
        rootView = HQScaledRoot(JobEditorView(model: model,
                                 pickModel: { [weak self] in self?.pushModelPicker() },
                                 pickBlueprint: { [weak self] in self?.pushBlueprintPicker() },
                                 head: head))
        title = model.title
        saveItem = UIBarButtonItem(title: model.actionTitle, primaryAction: UIAction { [weak self] _ in self?.save() })
        saveItem.style = .prominent
        saveItem.accessibilityIdentifier = "job.editor.save"
        navigationItem.rightBarButtonItem = saveItem
        navigationItem.backButtonDisplayMode = .minimal
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { model.isDirty }
    var isSaving: Bool { model.saving }

    /// ✕ (after `ChatSheet.wrap`): a pristine form closes at once, a changed one asks, a saving one holds.
    func installClose() {
        // [mac] Stress test 2026-10-28 #55: a form beside Save closes with Cancel on the leading edge on the Mac.
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.confirmLeaving { [weak self] in self?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "job.editor"
        view.backgroundColor = HQPalette.sheetPage
        observeForm()
        observeJobs()
        refreshBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !loaded {
            loaded = true
            Task { await model.load() }
        }
    }

    // MARK: Bar

    private func observeForm() {
        withObservationTracking {
            _ = model.canSave
            _ = model.saving
            _ = model.isDirty
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBar()
                self.observeForm()
            }
        }
    }

    /// The job changed elsewhere (`cron.changed`, a refresh): an untouched form takes the new values (D-J12).
    private func observeJobs() {
        guard model.isEdit else { return }
        withObservationTracking {
            _ = model.store.jobs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let job = self.model.job, let fresh = self.model.store.job(key: job.key), fresh != job { self.model.absorb(fresh) }
                self.observeJobs()
            }
        }
    }

    private func refreshBar() {
        if model.saving {
            if navigationItem.rightBarButtonItem === saveItem {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                let item = UIBarButtonItem(customView: spinner)
                item.accessibilityIdentifier = "job.editor.saving"
                item.accessibilityLabel = "Saving"
                navigationItem.rightBarButtonItem = item
            }
        } else {
            if navigationItem.rightBarButtonItem !== saveItem { navigationItem.rightBarButtonItem = saveItem }
            saveItem.setProminentEnabled(model.canSave)
        }
        navigationItem.leftBarButtonItem?.isEnabled = !model.saving
        if let navigation = navigationController {
            EditingGuard.refreshLock(navigation)
            if model.saving { EditingGuard.dropQuestion() }
        }
    }

    // MARK: Save

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(title: model.actionTitle, action: #selector(saveFromKeyboard), input: "\r", modifierFlags: .command)
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func saveFromKeyboard() { save() }

    /// One write for any number of taps. An unchanged edit sends nothing; an incomplete form says what is missing.
    private func save() {
        guard !model.saving else { return }
        if model.isEdit && model.isComplete && model.updates() == nil { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.model.save()
            switch outcome {
            case .failed:
                PagesHaptics.error()
                if let navigation = self.navigationController, navigation.topViewController !== self {
                    navigation.popToViewController(self, animated: true)
                }
                if let reason = self.model.failure {
                    _ = HQAnnounce.say("Couldn’t save the job. \(reason)")
                }
            case .created, .saved:
                let done = self.onDone
                self.refreshBar()
                (self.navigationController ?? self).dismiss(animated: true) { done(outcome) }
            }
        }
    }

    // MARK: Pickers

    private func pushModelPicker() {
        guard !model.saving, navigationController?.topViewController === self else { return }
        view.endEditing(true)
        if model.modelsState == .failed { Task { await model.reloadModels() } }
        navigationController?.pushViewController(JobModelPickerViewController(model: model), animated: true)
    }

    private func pushBlueprintPicker() {
        guard !model.saving, navigationController?.topViewController === self else { return }
        view.endEditing(true)
        navigationController?.pushViewController(JobBlueprintPickerViewController(model: model), animated: true)
    }
}

// MARK: - Pushed pickers

@MainActor @Observable
final class JobPickerQuery {
    var text = ""
}

/// A picker pushed inside the sheet: small title, the system back button, a search field when the list is long.
class JobPickerController: UIHostingController<HQScaledRoot<AnyView>>, UISearchResultsUpdating {
    let query = JobPickerQuery()

    init(title: String, root: AnyView) {
        super.init(rootView: HQScaledRoot(root))
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
    }

    func setSearch(_ shown: Bool, placeholder: String) {
        guard shown != (navigationItem.searchController != nil) else { return }
        if shown {
            let search = UISearchController(searchResultsController: nil)
            search.obscuresBackgroundDuringPresentation = false
            search.searchResultsUpdater = self
            search.searchBar.placeholder = placeholder
            navigationItem.searchController = search
            navigationItem.hidesSearchBarWhenScrolling = false
        } else {
            navigationItem.searchController = nil
            query.text = ""
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        if text != query.text { query.text = text }
    }

    func picked() {
        PagesHaptics.selection()
        navigationItem.searchController?.isActive = false
        navigationController?.popViewController(animated: true)
    }
}

final class JobModelPickerViewController: JobPickerController {
    private let model: JobEditorModel

    init(model: JobEditorModel) {
        self.model = model
        super.init(title: "Model", root: AnyView(EmptyView()))
        rootView = HQScaledRoot(AnyView(JobModelPickerView(model: model, query: query) { [weak self] in self?.picked() }))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "job.editor.models"
        observe()
    }

    /// Search only when there is something to search (more than 20 models).
    private func observe() {
        let count = withObservationTracking { model.providers.reduce(0) { $0 + $1.models.count } } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        setSearch(count > 20, placeholder: "Search Models")
    }
}

final class JobBlueprintPickerViewController: JobPickerController {
    init(model: JobEditorModel) {
        super.init(title: "Blueprints", root: AnyView(EmptyView()))
        rootView = HQScaledRoot(AnyView(JobBlueprintPickerView(model: model, query: query) { [weak self] in self?.picked() }))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "job.editor.blueprints"
        setSearch(true, placeholder: "Search Blueprints")
    }
}

/// A row with a trailing checkmark, the whole row the button.
struct JobCheckRow: View {
    var title: String
    var note: String?
    var checked: Bool
    var enabled = true
    /// A mark before the words (a platform, a bot's face, a template's symbol).
    var icon: AnyView?
    var identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { icon.opacity(enabled ? 1 : 0.5) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(enabled ? Color.hqLabel : Color.hqLabel3)
                        .multilineTextAlignment(.leading)
                    if let note, !note.isEmpty {
                        Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if checked {
                    Image(systemName: "checkmark")
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(Color.hqTint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, note?.isEmpty == false ? 4 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(checked ? "selected" : (note ?? ""))
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
        .disabled(!enabled)   // after the accessibility element, so VoiceOver says "dimmed"
    }
}

struct JobModelPickerView: View {
    var model: JobEditorModel
    var query: JobPickerQuery
    var done: () -> Void

    private func choose(_ choice: JobModelChoice?) {
        model.form.model = choice
        done()
    }

    var body: some View {
        let words = query.text.pgTrim.lowercased()
        let providers = model.providers
        let names = providers.flatMap { provider in provider.models.map { ModelNames.displayModelName($0, provider: provider.slug) } }
        let repeated = Set(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)
        List {
            if words.isEmpty {
                Section {
                    JobCheckRow(title: "Default (global model)", checked: model.form.model == nil, identifier: "job.editor.model.default") { choose(nil) }
                } footer: { HQSectionFooter {
                    Text("Uses whatever model this bot is set to.")
                } }
                if let pinned = model.unlistedModel {
                    Section {
                        JobCheckRow(title: ModelNames.displayModelName(pinned.model, provider: pinned.provider), note: pinned.model, checked: true,
                                    identifier: "job.editor.model.current") { choose(pinned) }
                    } header: { HQSectionLabel { Text("Current") } }
                }
            }
            switch model.modelsState {
            case .loading:
                Section { HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 6) }
            case .failed:
                Section {
                    Text("Couldn’t load the models.").foregroundStyle(Color.hqLabel2)
                    Button("Try Again") { Task { await model.reloadModels() } }
                        .accessibilityIdentifier("job.editor.models.retry")
                }
            case .loaded:
                ForEach(providers) { provider in
                    let shown = provider.models.filter { id in
                        words.isEmpty || id.lowercased().contains(words) || ModelNames.displayModelName(id, provider: provider.slug).lowercased().contains(words)
                            || provider.name.lowercased().contains(words)
                    }
                    if !shown.isEmpty {
                        Section {
                            ForEach(shown, id: \.self) { id in
                                let name = ModelNames.displayModelName(id, provider: provider.slug)   // [provider-manager]
                                let choice = JobModelChoice(provider: provider.slug, model: id)
                                JobCheckRow(title: name, note: repeated.contains(name) ? id : nil, checked: model.form.model == choice,
                                            identifier: "job.editor.model.\(provider.slug).\(id)") { choose(choice) }
                            }
                        } header: { HQSectionLabel { Text(ProviderPrefs.active.providerName(provider.slug) ?? ModelNames.plainProviderName(provider.name)) } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .hqGroupedPage()   // [desktoplook] the page follows the skin
    }
}

struct JobBlueprintPickerView: View {
    var model: JobEditorModel
    var query: JobPickerQuery
    var done: () -> Void

    var body: some View {
        let words = query.text.pgTrim.lowercased()
        let shown = model.blueprints.filter { JobBlueprints.matches($0, words) }
        List {
            if words.isEmpty {
                Section {
                    JobCheckRow(title: "Write Your Own", checked: model.form.blueprintKey == nil,
                                icon: AnyView(JobSymbolTile(symbol: "square.and.pencil", size: 30, tint: .hqTint)),
                                identifier: "job.editor.start.custom") {
                        model.chooseBlueprint(nil)
                        done()
                    }
                }
            }
            Section {
                ForEach(shown) { blueprint in
                    JobCheckRow(title: blueprint.title, note: blueprint.description, checked: model.form.blueprintKey == blueprint.key,
                                icon: AnyView(JobSymbolTile(symbol: JobTemplateSymbol.name(blueprint), size: 30, tint: .hqTint)),
                                identifier: "job.editor.start.\(blueprint.key)") {
                        model.chooseBlueprint(blueprint.key)
                        done()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .overlay {
            if shown.isEmpty && !words.isEmpty { ContentUnavailableView.search(text: query.text.pgTrim) }
        }
    }
}
