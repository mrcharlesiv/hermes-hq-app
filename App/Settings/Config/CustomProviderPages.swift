// [custom-providers] Settings › Providers › Your Providers: the OpenAI-compatible services added by hand (a local model
// server, Together, a company proxy), each with its own page to rename it, change its address, key, connection and
// default model, test it, make it the default, or delete it. Saved on the gateway through the calls the Hermes desktop
// app's Custom Endpoints page makes (`CustomProviders.swift`), so both apps show the same names. Keys are typed, never
// shown or kept here.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class CustomProvidersModel {
    var providers: [CustomProvider] = []
    var loaded = false
    var loadError: String?
    /// [provider-add] A delete from the list (swipe or menu) that failed, shown on the Providers page.
    var listFailure: String?
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool
    @ObservationIgnored let account: String?
    /// The app's own names and short lists for this account (`ProviderPrefs`); tests give their own.
    @ObservationIgnored var prefsStore: ProviderPrefsStore?

    init(api: GatewaySettingsAPI?, readOnly: Bool, account: String?) {
        self.api = api
        self.readOnly = readOnly
        self.account = account
    }

    func load() async {
        guard let api else { return }
        do {
            providers = try await api.customProviders()
            loaded = true
            loadError = nil
        } catch {
            AppLog.note("settings", "custom providers load failed: \(type(of: error))")
            loadError = SettingsErrorText.load(error)
        }
    }

    func provider(_ id: String) -> CustomProvider? { providers.first { $0.id == id } }

    /// Adds or edits one. The chat menus read the catalogue again on their next open, so a new name shows there too.
    func save(_ draft: CustomProviderDraft) async throws {
        guard !readOnly else { throw CustomProviderFailure(BotWriteError.readOnlyReason) }
        guard let api else { throw CustomProviderFailure(SettingsErrorText.offline) }
        providers = try await api.saveCustomProvider(draft)
        changed()
        AppLog.note("settings", "custom provider \(draft.isNew ? "added" : "saved")")
    }

    func delete(_ id: String) async throws {
        guard !readOnly else { throw CustomProviderFailure(BotWriteError.readOnlyReason) }
        guard let api else { throw CustomProviderFailure(SettingsErrorText.offline) }
        providers = try await api.deleteCustomProvider(id)
        changed()
        // [provider-manager] Its names, hidden models and added models go with it (adding it again starts fresh).
        if provider(id) == nil, let store = prefsStore ?? ProviderPrefsStore.current ?? account.map({ ProviderPrefsStore.of(accountId: $0) }) {
            store.update { $0.forget(provider: ProviderPrefs.endpointSlug(id)) }
        }
        AppLog.note("settings", "custom provider deleted")
    }

    func makeDefault(_ id: String) async throws {
        guard !readOnly else { throw CustomProviderFailure(BotWriteError.readOnlyReason) }
        guard let api else { throw CustomProviderFailure(SettingsErrorText.offline) }
        try await api.activateCustomProvider(id)
        changed()
        await load()
        AppLog.note("settings", "custom provider made default")
    }

    /// [provider-manager] A rename from the provider's page: the saved entry under a new name (the id, and so its
    /// chats, kept; no key sent).
    func rename(_ provider: CustomProvider, to name: String) async throws {
        var draft = CustomProviderDraft(provider)
        draft.name = name
        try await save(draft)
    }

    /// [provider-manager] Add Model…: the model id joins the endpoint's saved models on the gateway.
    func addModel(_ model: String, to provider: CustomProvider) async throws {
        var draft = CustomProviderDraft(provider)
        draft.addModels = [model]
        try await save(draft)
    }

    func test(_ draft: CustomProviderDraft) async throws -> CustomProviderTest {
        guard let api else { throw CustomProviderFailure(SettingsErrorText.offline) }
        return try await api.testCustomProvider(draft)
    }

    private func changed() {
        if let account { ModelCatalogCache.shared.markStale(account: account) }
    }
}

/// A refusal in words, shown as it is.
struct CustomProviderFailure: Error, LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private extension SettingsErrorText {
    static var offline: String { "Hermes HQ can’t reach your gateway right now. Try again when it’s back." }
}

// MARK: - Pushes

@MainActor
enum CustomProviderPages {
    /// A provider's page, or an empty one (nil) to add one.
    static func open(_ provider: CustomProvider?, model: CustomProvidersModel, router: SettingsRouter) {
        let draft = provider.map(CustomProviderDraft.init) ?? CustomProviderDraft()
        router.push(provider?.name ?? "New Provider", CustomProviderEditor(model: model, router: router, original: draft))
    }

    /// Delete, after asking (the provider's page and, [provider-add], its row in the list). `done` gets the failure in
    /// words, or nil once it is gone. Worded Remove, as the list's swipe and the provider's page say it.
    static func confirmDelete(_ provider: CustomProvider, model: CustomProvidersModel, from presenter: UIViewController?,
                              started: @escaping () -> Void = {}, done: @escaping (String?) -> Void) {
        TextPrompt.confirm(title: "Remove \(provider.name)?",
                           message: "It and its saved key are removed from \(HostWord.phrase). This can’t be undone.",
                           action: "Remove", from: presenter) {
            started()
            Task {
                do {
                    try await model.delete(provider.id)
                    Haptics.play(.success)
                    done(nil)
                } catch {
                    AppLog.note("settings", "custom provider delete failed: \(type(of: error))")
                    Haptics.play(.error)
                    done((error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error))
                }
            }
        }
    }
}

// MARK: - A provider's page

struct CustomProviderEditor: View {
    let model: CustomProvidersModel
    let router: SettingsRouter
    /// As saved when the page opened (empty while adding).
    let original: CustomProviderDraft
    @State private var draft = CustomProviderDraft()
    @State private var started = false
    @State private var saving = false
    @State private var testing = false
    @State private var busy = false
    @State private var test: CustomProviderTest?
    /// What the shown test was for (address, key, connection): changing any of them hides it.
    @State private var testedFor: [String] = []
    @State private var failure: String?

    private var saved: CustomProvider? { original.isNew ? nil : model.provider(original.id) }
    private var testSignature: [String] { [draft.baseURL, draft.key, draft.mode.rawValue] }
    /// The test result, while the fields it tested are unchanged.
    private var shownTest: CustomProviderTest? { testedFor == testSignature ? test : nil }
    private var locked: Bool { model.readOnly || saving || busy }
    private var canSave: Bool { draft.canSave && (original.isNew || draft.differs(from: original)) && !locked }

    var body: some View {
        ScrollViewReader { proxy in
            list.onChange(of: failure) { _, now in
                if now != nil { HQMotion.withAnimation { proxy.scrollTo(SaveFailureSection.anchor, anchor: .top) } }
            }
        }
    }

    private var list: some View {
        List { Group {
            if let failure {
                SaveFailureSection(text: failure, detail: nil, retry: nil, dismiss: { self.failure = nil })
            }
            providerSection
            connectionSection
            keySection
            modelsSection
            if let saved {
                if saved.isCurrent {
                    Section {
                        // [model-scope] Owner 2026-11-03: it is the default bot's (activate writes the default profile).
                        Text(SettingsWords.customProviderIsDefault(defaultBot: router.defaultBotName))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .hqRowPadding(4)
                            .accessibilityIdentifier("custom-provider.is-default")
                    }
                } else if !model.readOnly {
                    Section {
                        Button(busy ? "Working…" : "Make Default") { makeDefault(saved) }
                            .disabled(locked || draft.differs(from: original))
                            .hqMacFormButton()
                            .accessibilityIdentifier("custom-provider.make-default")
                    } footer: { HQSectionFooter {
                        // [model-scope] Owner 2026-11-03: whose default it becomes (the default bot's alone).
                        Text(draft.differs(from: original) ? "Save your changes first."
                             : SettingsWords.customProviderDefaultFooter(model: saved.model.isEmpty ? nil : ModelNames.displayModelName(saved.model),
                                                                         provider: saved.name, defaultBot: router.defaultBotName))
                            .accessibilityIdentifier("custom-provider.make-default-footer")
                    } }
                }
                if saved.canDelete, !model.readOnly {
                    Section {
                        Button("Remove Provider", role: .destructive) { askDelete(saved) }
                            .disabled(locked)
                            .hqMacFormButton(destructive: true)
                            .accessibilityIdentifier("custom-provider.delete")
                    } footer: { HQSectionFooter {
                        Text("Removes it and its saved key from \(HostWord.phrase).")
                    } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .scrollDismissesKeyboard(.interactively)
        .saveFailureFeedback(failure)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else if !model.readOnly {
                    Button(original.isNew ? "Add" : "Save") { save() }
                        .keyboardShortcut(.return, modifiers: .command)   // ⌘Return saves, as in New Job
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("custom-provider.save")
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            draft = original
        }
        .accessibilityIdentifier("custom-provider.page")
    }

    // MARK: Sections

    private var providerSection: some View {
        Section {
            ProviderFieldRow(label: "Name", placeholder: "e.g. Home Server", text: $draft.name, capitalize: true,
                             identifier: "custom-provider.name")
            ProviderFieldRow(label: "Address", placeholder: "http://127.0.0.1:8080/v1", text: $draft.baseURL, keyboard: .URL,
                             identifier: "custom-provider.address")
        } footer: { HQSectionFooter {
            if let problem = draft.addressProblem {
                Text(problem).foregroundStyle(Color.hqRed).accessibilityIdentifier("custom-provider.address-problem")
            } else {
                Text("The name is what model menus show, here and in the Hermes desktop app. The address usually ends in /v1.")
            }
        } }
        .disabled(locked)
    }

    private var connectionSection: some View {
        Section {
            if DeviceWord.isMac {
                // The form's bordered pop-up in the field column, as Name and Address above it.
                MacFormRow(label: "Connection") {
                    MacPopUp(label: "Connection", selection: $draft.mode, options: CustomProviderMode.allCases) { $0.title }
                }
                .disabled(locked)
                .accessibilityIdentifier("custom-provider.mode")
            } else {
                Picker("Connection", selection: $draft.mode) {
                    ForEach(CustomProviderMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .hqMenuPicker()
                .disabled(locked)
                .accessibilityIdentifier("custom-provider.mode")
            }
            Button(testing ? "Testing…" : "Test Connection") { runTest() }
                .disabled(testing || draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty || draft.addressProblem != nil)
                .hqMacPushButton(leading: true)
                .accessibilityIdentifier("custom-provider.test")
            if let test = shownTest {
                // Under the button's words, not a list icon's column away from them.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(test.ok ? Color.green : Color.hqRed)
                    Text(test.summary).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                }
                .hqRowPadding(4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("custom-provider.test-result")
            }
        } footer: { HQSectionFooter {
            Text("Automatic suits most services. Pick another only if the service says it needs it.")
        } }
    }

    private var keySection: some View {
        Section {
            ProviderFieldRow(label: "Key", placeholder: keyPlaceholder, text: $draft.key, secure: true,
                             identifier: "custom-provider.key")
                .disabled(locked)
            if saved?.hasKey == true, draft.key.isEmpty {
                if draft.removeKey {
                    Button("Keep Saved Key") { draft.removeKey = false }
                        .disabled(locked)
                        .hqMacPushButton(leading: true)
                        .accessibilityIdentifier("custom-provider.keep-key")
                } else if !model.readOnly {
                    Button("Remove Key", role: .destructive) { draft.removeKey = true }
                        .disabled(locked)
                        .hqMacPushButton(leading: true, destructive: true)
                        .accessibilityIdentifier("custom-provider.remove-key")
                }
            }
        } footer: { HQSectionFooter {
            Text(keyFooter)
        } }
    }

    private var keyPlaceholder: String {
        if draft.removeKey { return "Removed when you save" }
        return saved?.hasKey == true ? "Saved · type to replace" : "Optional"
    }

    private var keyFooter: String {
        if draft.removeKey { return "The saved key is removed when you save." }
        return "Saved on \(HostWord.phrase), never in Hermes HQ. Leave it empty if the service needs none."
    }

    private var modelsSection: some View {
        Section {
            ChooserRow(title: "Default Model", value: draft.model.isEmpty ? nil : ModelNames.displayModelName(draft.model)) {
                router.push("Default Model", CustomProviderModelChooser(choices: choices, current: draft.model) { picked in
                    draft.choose(picked)
                    router.navigation?.popViewController(animated: true)
                })
            }
            .disabled(locked)
            .accessibilityIdentifier("custom-provider.model")
            SwitchRow(title: "Find Models Automatically", isOn: $draft.discoverModels, disabled: locked)
                .accessibilityIdentifier("custom-provider.discover")
            ProviderFieldRow(label: "Context Window", placeholder: "Automatic", text: $draft.contextLength, keyboard: .numberPad,
                             identifier: "custom-provider.context")
                .disabled(locked)
        } header: { HQSectionLabel {
            Text("Models")
        } } footer: { HQSectionFooter {
            if let problem = draft.contextProblem {
                Text(problem).foregroundStyle(Color.hqRed)
            } else {
                Text(modelsFooter)
            }
        } }
    }

    private var modelsFooter: String {
        let discover = draft.discoverModels ? "Hermes asks the service which models it has." : "Only the models saved for it are offered."
        let context = original.contextLength.isEmpty
            ? "Context Window is the most a chat can hold, in tokens; empty lets Hermes work it out."
            : "Context Window is the most a chat can hold, in tokens."
        return "\(discover) \(context)"
    }

    /// The default model's choices: saved, found by Test Connection, and the one chosen.
    private var choices: [String] {
        var all = draft.models
        if let test = shownTest, test.ok { for name in test.models where !all.contains(name) { all.append(name) } }
        if !draft.model.isEmpty, !all.contains(draft.model) { all.insert(draft.model, at: 0) }
        return all
    }

    // MARK: Actions

    private func runTest() {
        guard !testing else { return }
        testing = true
        test = nil
        // The keyboard steps aside so the result and the models found show.
        if !DeviceWord.isMac { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        let sent = draft
        Task {
            defer { testing = false }
            do {
                let answer = try await model.test(sent)
                test = answer
                draft.apply(answer)
                testedFor = testSignature   // after a resolved address replaced the typed root
                Haptics.play(answer.ok ? .success : .error)
            } catch {
                AppLog.note("settings", "custom provider test failed: \(type(of: error))")
                test = CustomProviderTest(ok: false, reachable: false, message: SettingsErrorText.save(error))
                testedFor = testSignature
                Haptics.play(.error)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        failure = nil
        let sent = draft
        Task {
            defer { saving = false }
            do {
                try await model.save(sent)
                Haptics.play(.success)
                router.navigation?.popViewController(animated: true)
            } catch {
                AppLog.note("settings", "custom provider save failed: \(type(of: error))")
                failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    private func makeDefault(_ provider: CustomProvider) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await model.makeDefault(provider.id)
                Haptics.play(.success)
            } catch {
                AppLog.note("settings", "custom provider make default failed: \(type(of: error))")
                failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    private func askDelete(_ provider: CustomProvider) {
        CustomProviderPages.confirmDelete(provider, model: model, from: router.presenter, started: {
            busy = true
            failure = nil
        }) { problem in
            busy = false
            if let problem { failure = problem } else { router.navigation?.popViewController(animated: true) }
        }
    }
}

// MARK: - A labelled field

/// One field of the page: the label beside it on the iPhone (as Settings' own forms), the Mac form's label column and
/// field box on the Mac.
private struct ProviderFieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure = false
    var capitalize = false
    let identifier: String

    var body: some View {
        if DeviceWord.isMac {
            MacFormRow(label: label) { field.hqMacFieldBox() }
        } else {
            LabeledContent {
                field.multilineTextAlignment(.trailing)
            } label: {
                Text(label).foregroundStyle(Color.hqLabel)
            }
            .hqRowPadding(4)
        }
    }

    @ViewBuilder private var field: some View {
        let prompt = DeviceWord.isMac ? MacField.prompt(placeholder) : Text(placeholder)
        Group {
            if secure {
                SecureField(label, text: $text, prompt: prompt)
            } else {
                TextField(label, text: $text, prompt: prompt)
            }
        }
        .textInputAutocapitalization(capitalize ? .words : .never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Default Model

/// The provider's models to pick its default from, with a search once there are many and a field for one not listed.
struct CustomProviderModelChooser: View {
    let choices: [String]
    let current: String
    let pick: (String) -> Void
    @State private var query = ""
    @State private var typed = ""

    private var shown: [String] {
        query.isEmpty ? choices : choices.filter {
            $0.localizedCaseInsensitiveContains(query) || ModelNames.displayModelName($0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List { Group {
            if choices.count > 8 {
                Section {
                    TextField("Search Models", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .hqRowPadding(4)
                        .accessibilityIdentifier("custom-provider.models.search")
                }
            }
            if !choices.isEmpty {
                Section {
                    ForEach(shown, id: \.self) { name in
                        Button {
                            Haptics.play(.selection)
                            pick(name)
                        } label: {
                            HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : nil) {
                                HQRadioMark(selected: name == current)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ModelNames.displayModelName(name)).foregroundStyle(Color.hqLabel)
                                    if ModelNames.displayModelName(name) != name {
                                        Text(name).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                    }
                                }
                                Spacer()
                                HQCheckMark(selected: name == current)
                            }
                            .hqRowPadding(4)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("custom-provider.models.\(name)")
                        .hqRadioRow()
                    }
                } footer: { HQSectionFooter {
                    if shown.isEmpty { Text("No model matches “\(query)”.") }
                } }
            }
            Section {
                TextField("Model name", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(useTyped)
                    .hqRowPadding(4)
                    .accessibilityIdentifier("custom-provider.models.typed")
                Button("Use This Model", action: useTyped)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    .hqMacPushButton(leading: true)
                    .accessibilityIdentifier("custom-provider.models.use")
            } header: { HQSectionLabel {
                Text(choices.isEmpty ? "Model" : "Another Model")
            } } footer: { HQSectionFooter {
                Text(choices.isEmpty ? "Type the model’s name as the service spells it, or go back and use Test Connection to list its models."
                     : "Type the model’s name as the service spells it.")
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .accessibilityIdentifier("custom-provider.models.page")
    }

    private func useTyped() {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        pick(name)
    }
}
