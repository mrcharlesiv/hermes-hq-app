// Settings › Model (`vendor/.../settings/model-settings.tsx`, `fallback-models-field.tsx`): Main Model (provider and
// model, applied with `POST /api/model/set` scope main — an expensive model asks first — plus Reasoning Effort and Fast
// Mode as sparse config writes), Fallback Models (`fallback_providers`), Auxiliary Models (each helper task's model,
// `POST /api/model/set` scope auxiliary) and Mixture of Agents (`GET`/`PUT /api/model/moa`). Main Model is the default
// profile's; each bot's own is its Bot Info › Default Model (`BotDefaultModel`, the same call with `?profile=`), and
// its own Fallback Models and Auxiliary Models are these pages on its `?profile=` (`BotModelPages`).

import Observation
import SwiftUI
import UIKit

// MARK: - The provider catalog

@MainActor @Observable
final class ModelCatalogModel {
    /// [provider-manager] As the menus show them: the owner's names, hidden models left out (the one in use kept), and
    /// models added by hand (`ProviderPrefs`). `raw` is the gateway's own answer.
    var providers: [ModelProviderOption] { raw.map { $0.applying(prefs, keep: $0.slug == mainProvider ? mainModel : nil) } }
    var raw: [ModelProviderOption] = []
    /// Read again when the names or short lists change (another page, another device).
    var prefs = ProviderPrefs.active
    @ObservationIgnored private var prefsWatch: NSObjectProtocol?
    var mainProvider = ""
    var mainModel = ""
    var loading = false
    var loadError: String?
    /// A load has gone through (an empty catalog after one is the gateway's answer, not one on its way).
    var loaded = false
    @ObservationIgnored let api: GatewaySettingsAPI?

    init(api: GatewaySettingsAPI?) {
        self.api = api
        prefsWatch = NotificationCenter.default.addObserver(forName: ProviderPrefsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefs = ProviderPrefs.active }
        }
    }

    isolated deinit { if let prefsWatch { NotificationCenter.default.removeObserver(prefsWatch) } }

    /// A model's name under a provider: the owner's, else the usual one.
    func modelName(_ provider: String, _ model: String) -> String {
        prefs.modelName(provider: provider, model: model) ?? ModelNames.displayModelName(model)
    }

    func load() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let options = api.modelOptions()
            async let info = api.modelInfo()
            let (rows, main) = try await (options, info)
            raw = rows
            prefs = ProviderPrefs.active
            mainProvider = main["provider"]?.string ?? ""
            mainModel = main["model"]?.string ?? ""
            loadError = nil
            loaded = true
        } catch {
            AppLog.note("settings", "model catalog failed: \(type(of: error))")
            loadError = SettingsErrorText.load(error)
        }
    }

    func provider(_ slug: String) -> ModelProviderOption? {
        providers.first { $0.slug == slug } ?? providers.first { $0.slug.lowercased() == slug.lowercased() }
    }

    func providerName(_ slug: String) -> String {
        if slug.isEmpty { return "None" }
        return provider(slug)?.name ?? ConfigText.pretty(slug)
    }

    /// "Claude Opus 5.5 · Anthropic".
    func describe(provider: String, model: String) -> String {
        guard !model.isEmpty else { return DeviceWord.isMac ? ConfigUnits.none : "Not Set" }   // [mac] Stress test 2026-10-28 #101
        return "\(modelName(provider, model)) · \(providerName(provider))"
    }
}

/// Picks a provider, then one of its models (`ModelSelect`): a provider without models offers a typed model name.
struct ModelChooserView: View {
    let catalog: ModelCatalogModel
    let title: String
    var currentProvider: String
    var currentModel: String
    /// MoA slots can't be the `moa` provider itself.
    var excludeMoa = false
    /// Under the provider: whose model this is (a bot's own Default Model).
    var note: String? = nil
    let pick: (_ provider: String, _ model: String) -> Void
    @State private var provider: String = ""
    @State private var custom = ""
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { Group {
            // A bot's own catalog is read here, after the push (the other pages read theirs first): "Loading…" until it
            // comes, and a failure says why with Try Again rather than leaving a blank page.
            if catalog.providers.isEmpty, let error = catalog.loadError, !catalog.loading {
                LoadFailureSection(title: "Couldn’t Load Models", text: error) { Task { await catalog.load() } }
            } else if catalog.providers.isEmpty, !catalog.loaded {
                LoadingSection()
            } else {
                choices
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .onAppear {
            if provider.isEmpty { provider = currentProvider }
        }
        .task { if catalog.providers.isEmpty { await catalog.load() } }
    }

    @ViewBuilder private var choices: some View {
        Section {
            Picker("Provider", selection: $provider) {
                if provider.isEmpty || catalog.provider(provider) == nil {
                    Text(provider.isEmpty ? "Choose" : catalog.providerName(provider)).tag(provider)
                }
                ForEach(catalog.providers.filter { !excludeMoa || $0.slug.lowercased() != "moa" }) { row in
                    Text(row.isReady ? row.name : "\(row.name) (Not Set Up)").tag(row.slug)
                }
            }
            .hqMenuPicker()
            .accessibilityIdentifier("model-chooser.provider")
        } header: { HQSectionLabel { Text("Provider") } } footer: { HQSectionFooter {
            if let note { Text(note).accessibilityIdentifier("model-chooser.note") }
        } }
        // [provider-manager] Hidden models are left out, but the one in use stays, so the current value is never lost.
        let listed = catalog.provider(provider)?.models ?? []
        let models = provider == currentProvider && !currentModel.isEmpty && !listed.contains(currentModel) && catalog.provider(provider) != nil
            ? [currentModel] + listed : listed
        if !models.isEmpty {
            Section {
                TextField("Search Models", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                ForEach(models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || catalog.modelName(provider, $0).localizedCaseInsensitiveContains(query) }, id: \.self) { model in
                    Button {
                        Haptics.play(.selection)
                        pick(provider, model)
                    } label: {
                        HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : nil) {   // [mac] Stress test 2026-10-28 #51 (round 6): the radio on the first line; [mac] round 7: the one radio gap
                            HQRadioMark(selected: provider == currentProvider && model == currentModel)   // [mac] Stress test 2026-10-28 #51: a leading radio on the Mac
                            VStack(alignment: .leading, spacing: 2) {
                                Text(catalog.modelName(provider, model)).foregroundStyle(Color.hqLabel)
                                if catalog.modelName(provider, model) != model {
                                    Text(model).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                }
                            }
                            Spacer()
                            HQCheckMark(selected: provider == currentProvider && model == currentModel)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("model-option.\(model)")
                    .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
                }
            } header: { HQSectionLabel { Text("Model") } }
        }
        if !provider.isEmpty {
            Section {
                TextField("Model name", text: $custom)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("model-chooser.custom")
                Button("Use This Model") {
                    pick(provider, custom.trimmingCharacters(in: .whitespaces))
                }
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { HQSectionLabel {
                Text(models.isEmpty ? "Model" : "Another Model")
            } } footer: { HQSectionFooter {
                if let row = catalog.provider(provider), !row.isReady {
                    Text("\(row.name) isn’t set up on \(HostWord.phrase) yet. Add its key in Settings › Providers, or sign in to it there.")
                }
            } }
        }
    }
}

// MARK: - Main Model

struct MainModelView: View {
    let store: GatewayConfigStore
    let router: SettingsRouter
    @State private var catalog: ModelCatalogModel
    @State private var applying = false
    @State private var applyError: String?
    /// The change that failed, for Try Again (UX #201).
    @State private var lastAttempt: (() -> Void)?
    @State private var keyDraft = ""
    /// The model change's own failure card, apart from the store's (`SaveFailureSection.anchor`) on the same page.
    static let applyFailureAnchor = "settings.model-failure"

    init(store: GatewayConfigStore, router: SettingsRouter) {
        self.store = store
        self.router = router
        _catalog = State(initialValue: ModelCatalogModel(api: router.gatewaySettings?.settingsAPI))
    }

    var body: some View {
        List { Group {
            if let applyError {
                SaveFailureSection(text: applyError, detail: nil, retry: lastAttempt.map { again in { self.applyError = nil; lastAttempt = nil; again() } },
                                   dismiss: { self.applyError = nil; lastAttempt = nil }, anchor: Self.applyFailureAnchor)
            }
            Section {
                let modelValue = catalog.loading && catalog.mainModel.isEmpty ? "Loading…"
                    : catalog.describe(provider: catalog.mainProvider, model: catalog.mainModel)
                if DeviceWord.isMac {
                    // [mac] Stress test 2026-10-28 #51 (review): a form row with a pop-up button that opens the chooser
                    // as a sheet, not a list row that pushes a page.
                    MacFormRow(label: "Model") { MacChooserButton(label: "Model", value: modelValue, action: openChooser) }
                        .accessibilityIdentifier("main-model.model")
                } else {
                    ValueRow(title: "Model", value: modelValue) {
                        openChooser()
                    }
                    .accessibilityIdentifier("main-model.model")
                }
                if applying {
                    HStack(spacing: 10) { ProgressView(); Text("Switching…").foregroundStyle(Color.hqLabel2) }
                }
            } header: { HQSectionLabel {
                // Tester batch 3: whose model this is (it was "Default Model", which read as every bot's).
                Text(SettingsWords.mainModelHeader(defaultBot: defaultBot))
            } } footer: { HQSectionFooter {
                if let error = catalog.loadError {
                    Text(error).foregroundStyle(Color.hqRed)
                } else {
                    Text(SettingsWords.mainModelFooter(defaultBot: defaultBot, otherBots: otherBots))
                        .accessibilityIdentifier("main-model.footer")
                }
            } }
            if let row = catalog.provider(catalog.mainProvider), !row.isReady, row.authType == "api_key", let keyEnv = row.keyEnv {
                Section {
                    SecureField("API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("main-model.key")
                    Button("Save Key") { saveKey(keyEnv) }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { HQSectionLabel {
                    Text("\(row.name) Key")
                } } footer: { HQSectionFooter {
                    Text("Saved on \(HostWord.phrase) as \(keyEnv). Hermes HQ never keeps it.")
                } }
            }
            if store.config != nil {
                Section {
                    if DeviceWord.isMac, let field = store.field("agent.reasoning_effort") {
                        // [mac] Stress test 2026-10-28 #51 (review): a pop-up in place, not a page for one choice.
                        MacConfigFieldRow(field: field, store: store, router: router, showsHelp: false)
                            .accessibilityIdentifier("main-model.reasoning")
                    } else {
                        NavigationChoiceRow(title: "Reasoning Effort",
                                            value: ConfigRenderer.optionLabel(key: "agent.reasoning_effort", ConfigCopy.reasoningEffort(store.value("agent.reasoning_effort")))) {
                            ConfigScreens.openField("agent.reasoning_effort", store: store, router: router)
                        }
                        .accessibilityIdentifier("main-model.reasoning")
                    }
                    SwitchRow(title: "Fast Mode", isOn: Binding(
                        get: { ConfigCopy.isFastTier(store.value("agent.service_tier")) },
                        set: { on in
                            Haptics.play(.selection)
                            store.set("agent.service_tier", .string(on ? "fast" : "normal"))
                        }))
                        .accessibilityIdentifier("main-model.fast")
                } header: { HQSectionLabel {
                    Text("Defaults")
                } } footer: { HQSectionFooter {
                    // [model-scope] Owner 2026-11-03: these are the default bot's too (`agent.*` in its config).
                    Text(SettingsWords.mainDefaultsFooter(defaultBot: defaultBot)).accessibilityIdentifier("main-model.defaults-footer")
                } }
            }
            ConfigFieldsContent(page: ConfigCatalog.page("model.main")!, store: store, router: router,
                                excluding: ["agent.reasoning_effort", "agent.service_tier", "model"], showsLoadState: true)
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        // Two cards can show at once (this page's own and the store's): each failure scrolls to its own card.
        .saveFailureFeedback(applyError, anchor: Self.applyFailureAnchor)
        .saveFailureFeedback(store.failure?.text)
        .task {
            await catalog.load()
            await store.load()
        }
        .refreshable {
            await catalog.load()
            await store.load(force: true)
        }
        .accessibilityIdentifier("main-model.list")
    }

    /// The gateway's own profile's bot (the default one), and whether there are others.
    private var defaultBot: String? { router.defaultBotName }
    private var otherBots: Bool { router.hasOtherBots }

    private func openChooser() {
        // [model-scope] Owner 2026-11-03: the chooser says whose model it changes, as the page's footer does.
        let view = ModelChooserView(catalog: catalog, title: "Model", currentProvider: catalog.mainProvider, currentModel: catalog.mainModel,
                                    note: SettingsWords.mainModelFooter(defaultBot: defaultBot, otherBots: otherBots)) { provider, model in
            router.closeChooser()
            apply(provider: provider, model: model, confirm: false)
        }
        router.openChooser("Model", view)   // [mac] Stress test 2026-10-28 #51: a sheet on the Mac
    }

    private func apply(provider: String, model: String, confirm: Bool) {
        guard !model.isEmpty else { return }
        if router.gatewaySettings?.isReadOnlyGateway == true {
            applyError = BotWriteError.readOnlyReason
            lastAttempt = nil
            return
        }
        guard let api = router.gatewaySettings?.settingsAPI else { return }
        applying = true
        applyError = nil
        let base = catalog.provider(provider)?.apiURL
        Task {
            defer { applying = false }
            do {
                try await api.setModel(scope: "main", provider: provider, model: model, baseURL: base, confirm: confirm)
                Haptics.play(.success)
                AppLog.note("settings", "main model changed")
                catalog.mainProvider = provider
                catalog.mainModel = model
                router.services.refreshBots()   // the default bot's Bot Info and Bot Profiles name the new model
                await catalog.load()
            } catch ModelSetError.confirm(let message) {
                TextPrompt.confirmPlain(title: "Use \(ModelNames.displayModelName(model, provider: provider))?", message: message, action: "Use It",
                                        from: router.presenter) {
                    apply(provider: provider, model: model, confirm: true)
                }
            } catch {
                AppLog.note("settings", "main model change failed: \(type(of: error))")
                applyError = SettingsErrorText.save(error)
                lastAttempt = { apply(provider: provider, model: model, confirm: confirm) }
            }
        }
    }

    private func saveKey(_ keyEnv: String) {
        guard let api = router.gatewaySettings?.settingsAPI else { return }
        let value = keyDraft.trimmingCharacters(in: .whitespaces)
        keyDraft = ""
        let start = ContinuousClock.now
        Task {
            do {
                try await api.setEnv(keyEnv, value: value, providerSetup: true)
                Haptics.play(.success)
                AppLog.trace("settings", "provider key \(keyEnv) saved in \(AppLog.ms(since: start)) ms")
                await catalog.load()
            } catch {
                AppLog.note("settings", "provider key \(keyEnv) save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                applyError = SettingsErrorText.save(error)
                lastAttempt = { keyDraft = value; saveKey(keyEnv) }
            }
        }
    }
}

/// A value row used for a picker that opens its own page.
struct NavigationChoiceRow: View {
    var title: String
    var value: String
    var action: () -> Void
    var body: some View { ValueRow(title: title, value: value, action: action) }
}

extension TextPrompt {
    /// A plain (not destructive) confirmation.
    @MainActor static func confirmPlain(title: String, message: String?, action: String, from presenter: UIViewController?,
                                        done: @escaping () -> Void) {
        guard let host = FailureAlert.topmost(presenter) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let go = UIAlertAction(title: action, style: .default) { _ in done() }
        alert.addAction(go)
        alert.preferredAction = go
        host.present(alert, animated: true)
    }
}

// MARK: - A bot's own Default Model

/// A bot's own default model (tester batch 3): Bot Info's Brain row and More › Bot Profiles' page open the chooser on
/// that bot's catalog (`/api/model/options?profile=`), and a pick is saved for that bot alone (`BotEditing.setDefaultModel`,
/// `POST /api/model/set?profile=`), asking first when the gateway says the model costs more. Failures say why, with Try
/// Again; the row says "Switching…" while the gateway answers.
@MainActor @Observable
final class BotDefaultModel {
    /// The bot whose model is being saved.
    private(set) var switching: String?
    /// After a save went through (a page that shows more of the bot reads it again).
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored let services: any AppServices

    init(services: any AppServices) { self.services = services }

    private var editing: (any BotEditing)? { (services as? SettingsServices)?.botEditing }
    private var api: GatewaySettingsAPI? { (services as? GatewaySettingsServices)?.settingsAPI }

    /// The row can open (signed in, with the bot editor).
    var available: Bool { editing != nil && api != nil }

    /// The row's value: the model's name, "Switching…" while one is saved.
    func value(_ bot: Bot) -> String {
        if switching == bot.id { return "Switching…" }
        return editing?.modelInfo(bot).model ?? (DeviceWord.isMac ? ConfigUnits.none : "Not Set")   // [mac] Stress test 2026-10-28 #101
    }

    /// Pushes the chooser for `bot` on `navigation`; a pick goes back to the page it came from and is saved.
    func open(_ bot: Bot, on navigation: UINavigationController?) {
        guard let navigation, let api, let editing else { return }
        Haptics.play(.selection)
        let catalog = ModelCatalogModel(api: GatewaySettingsAPI(client: api.client, profile: bot.id))
        let current = editing.defaultModel(bot)
        let chooser = ModelChooserView(catalog: catalog, title: "Default Model", currentProvider: current.provider ?? "",
                                       currentModel: current.model ?? "",
                                       note: SettingsWords.botModelScope(bot: bot.name, isDefault: BotModelPages.isDefault(bot.id))) {   // [model-scope]
            [weak self, weak navigation] provider, model in
            navigation?.popViewController(animated: true)
            self?.save(bot, provider: provider, model: model, baseURL: catalog.provider(provider)?.apiURL, confirm: false, from: navigation)
        }
        navigation.pushViewController(SettingsPageController(title: "Default Model", chooser), animated: true)
    }

    func save(_ bot: Bot, provider: String, model: String, baseURL: String?, confirm: Bool, from navigation: UINavigationController?) {
        guard let editing, !model.isEmpty, switching == nil else { return }
        switching = bot.id
        Task { [weak self] in
            do {
                try await editing.setDefaultModel(bot, provider: provider, model: model, baseURL: baseURL, confirm: confirm)
                self?.switching = nil
                Haptics.play(.success)
                AppLog.note("settings", "bot model changed")
                self?.onSaved?()
            } catch ModelSetError.confirm(let message) {
                self?.switching = nil
                TextPrompt.confirmPlain(title: "Use \(ModelNames.displayModelName(model, provider: provider))?", message: message, action: "Use It",
                                        from: navigation?.topViewController) { [weak self] in
                    self?.save(bot, provider: provider, model: model, baseURL: baseURL, confirm: true, from: navigation)
                }
            } catch {
                self?.switching = nil
                AppLog.note("settings", "bot model change failed: \(type(of: error))")
                FailureAlert.present(error, fallbackTitle: SettingsWords.botModelFailureTitle(bot.name), from: navigation?.topViewController) {
                    [weak self] in self?.save(bot, provider: provider, model: model, baseURL: baseURL, confirm: confirm, from: navigation)
                }
            }
        }
    }
}

// MARK: - A bot's own Fallback and Auxiliary Models

/// Tester 2026-10-30: "I can't change some important settings for individual profiles other than default from anywhere
/// in the app, like auxiliary model selection and fallback models selection." Bot Info › Brain and More › Bot Profiles
/// open Settings' Fallback Models and Auxiliary Models pages on that bot's own config (`/api/config?profile=`,
/// `/api/model/auxiliary?profile=`, `POST /api/model/set?profile=`), pushed on their own stack. The default bot's are
/// Settings' own (the shared store, so a change shows on both).
@MainActor enum BotModelPages {
    nonisolated static func isDefault(_ profile: String) -> Bool { profile.isEmpty || profile == "default" }

    /// The pages can open (signed in).
    static func available(_ services: any AppServices) -> Bool {
        (services as? GatewaySettingsServices)?.settingsAPI != nil
    }

    static func openFallbacks(_ bot: Bot, services: any AppServices, on navigation: UINavigationController?) {
        guard let navigation, let settings = services as? GatewaySettingsServices, let api = settings.settingsAPI else { return }
        let own = isDefault(bot.id)
        guard let store = own ? settings.configStore
                : GatewayConfigStore(api: GatewaySettingsAPI(client: api.client, profile: bot.id), readOnly: settings.isReadOnlyGateway)
        else { return }
        Haptics.play(.selection)
        let router = SettingsRouter(services: services, navigation: navigation)
        let page = SettingsPageController(title: "Fallback Models", FallbackModelsView(store: store, router: router, botName: own ? nil : bot.name))
        page.onDisappear = { store.flush() }
        router.push(page)
    }

    static func openAuxiliary(_ bot: Bot, services: any AppServices, on navigation: UINavigationController?) {
        guard let navigation, available(services) else { return }
        Haptics.play(.selection)
        let own = isDefault(bot.id)
        let router = SettingsRouter(services: services, navigation: navigation)
        router.push("Auxiliary Models", AuxiliaryModelsView(router: router, profile: own ? nil : bot.id, botName: own ? nil : bot.name))
    }
}

// MARK: - Whose models ([model-scope])

extension SettingsRouter {
    /// [model-scope] Settings' own model pages are the gateway's default profile's: its bot's name, and whether the
    /// roster has others (each with its own models in Bot Info › Brain).
    var defaultBotName: String? { services.bots.first { $0.id == "default" }?.name }
    var hasOtherBots: Bool { ((services as? SettingsServices)?.rosterCount ?? 0) > 1 }

    /// A model chooser's scope line: `bot`'s own page (opened from its Bot Info), else Settings' own (the default bot's).
    func modelScope(bot: String?) -> String {
        bot.map { SettingsWords.appliesOnly(to: $0) } ?? SettingsWords.defaultScope(defaultBot: defaultBotName, otherBots: hasOtherBots)
    }
}

// MARK: - Fallback Models

struct FallbackModelsView: View {
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// A bot's own list (`store` reads its `?profile=`): the footer says whose they are. Nil: the default profile's.
    var botName: String? = nil
    @State private var catalog: ModelCatalogModel
    /// [mac] The row picked for − (Stress test 2026-10-28 #51).
    @State private var selected: Int?

    init(store: GatewayConfigStore, router: SettingsRouter, botName: String? = nil) {
        self.store = store
        self.router = router
        self.botName = botName
        _catalog = State(initialValue: ModelCatalogModel(api: store.api))   // the store's own profile's providers
    }

    private var list: [FallbackModel] { FallbackModel.list(store.value("fallback_providers")) }

    private func add() {
        let view = ModelChooserView(catalog: catalog, title: "Add Fallback", currentProvider: "", currentModel: "",
                                    note: router.modelScope(bot: botName)) { provider, model in   // [model-scope]
            router.closeChooser()
            var next = list
            next.append(FallbackModel(provider: provider, model: model))
            store.set("fallback_providers", FallbackModel.value(next))
        }
        router.openChooser("Add Fallback", view)   // [mac] a sheet with Cancel, as every other model choice (Mac polish #40)
    }

    private func remove(_ index: Int) {
        var next = list
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        store.set("fallback_providers", FallbackModel.value(next))
        selected = next.isEmpty ? nil : min(index, next.count - 1)
    }

    private func move(_ index: Int, by step: Int) {
        var next = list
        let to = index + step
        guard next.indices.contains(index), next.indices.contains(to) else { return }
        next.swapAt(index, to)
        store.set("fallback_providers", FallbackModel.value(next))
        selected = to
    }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if store.config == nil {
                LoadingSection()
            } else {
                Section {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, entry in
                        // [mac] Mac polish #93: the number on the model's line, not halfway down to the provider's.
                        HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center) {
                            Text("\(index + 1).").foregroundStyle(Color.hqLabel2).monospacedDigit()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(catalog.modelName(entry.provider, entry.model)).foregroundStyle(Color.hqLabel)
                                Text(catalog.providerName(entry.provider)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            }
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fallback-row-\(index)")
                        // [mac] Stress test 2026-10-28 #51: a click picks the row for −, as in a Mac table; its menu
                        // moves it (no iOS edit mode with ⊖ and ≡).
                        .listRowBackground(DeviceWord.isMac && selected == index ? Color.hqTint.opacity(0.18) : nil)
                        .onTapGesture { if DeviceWord.isMac { selected = index } }
                        .contextMenu {
                            if DeviceWord.isMac {
                                Button("Move Up", systemImage: "arrow.up") { move(index, by: -1) }.disabled(index == 0)
                                Button("Move Down", systemImage: "arrow.down") { move(index, by: 1) }.disabled(index == list.count - 1)
                                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(index) }
                            }
                        }
                    }
                    .onDelete { offsets in
                        var next = list
                        next.remove(atOffsets: offsets)
                        store.set("fallback_providers", FallbackModel.value(next))
                    }
                    .onMove { from, to in
                        var next = list
                        next.move(fromOffsets: from, toOffset: to)
                        store.set("fallback_providers", FallbackModel.value(next))
                    }
                    if DeviceWord.isMac {
                        // [mac] Stress test 2026-10-28 #51: + and − under the list, as a Mac table has.
                        // [mac] Stress test 2026-10-28 round 7: the Mac's list-editor pair (one bordered box, two
                        // square cells), not iOS's tinted and grey capsules.
                        HStack(spacing: 0) {
                            MacAddRemoveButtons(addLabel: "Add Fallback Model", removeLabel: "Remove Fallback Model",
                                                addHelp: "Add Fallback Model…", removeHelp: "Remove the Selected Fallback",
                                                canRemove: selected != nil && !list.isEmpty, add: add,
                                                remove: { if let selected { remove(selected) } },
                                                addIdentifier: "fallback.add", removeIdentifier: "fallback.remove")
                            Spacer(minLength: 0)
                        }
                    } else {
                    Button(action: add) {
                        Label("Add Fallback Model…", systemImage: "plus")
                    }
                    .accessibilityIdentifier("fallback.add")
                    }
                } footer: { HQSectionFooter {
                    Text(SettingsWords.botScoped(list.isEmpty ? "No fallback models. If the default model fails, the chat shows the error."
                         : DeviceWord.isMac ? "Tried in order when the default model fails. Click one, then − to remove it; \(DeviceWord.hold) it to reorder."   // [mac] Stress test 2026-10-28 round 9: no "or down." alone on a line; Mac polish #135: never "Control-" alone
                         : "Tried in order when the default model fails. \(DeviceWord.Tap) the red button to remove one; drag the handle to reorder.",
                                                 bot: botName, defaultBot: router.defaultBotName, otherBots: router.hasOtherBots))   // [model-scope]
                        .accessibilityIdentifier("fallbacks.footer")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        // [mac] Always in Edit mode with a fallback listed: a lone one had only a swipe to remove it, which a mouse can't do.
        .environment(\.editMode, .constant(list.isEmpty || DeviceWord.isMac ? .inactive : .active))
        .task {
            await store.load()
            await catalog.load()
        }
        .accessibilityIdentifier("fallbacks.list")
    }
}

// MARK: - Auxiliary Models

@MainActor @Observable
final class AuxiliaryModel {
    var tasks: [AuxiliaryAssignment] = []
    var loaded = false
    var error: String?
    var busy: String?
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool

    init(api: GatewaySettingsAPI?, readOnly: Bool) {
        self.api = api
        self.readOnly = readOnly
    }

    func load() async {
        guard let api else { return }
        do {
            tasks = try await api.auxiliary()
            loaded = true
            error = nil
        } catch {
            AppLog.note("settings", "auxiliary models load failed: \(type(of: error))")
            self.error = SettingsErrorText.load(error)
        }
    }

    func set(_ task: String, provider: String, model: String, baseURL: String?) async -> String? {
        guard !readOnly else { return BotWriteError.readOnlyReason }
        guard let api else { return nil }
        busy = task
        defer { busy = nil }
        let start = ContinuousClock.now
        do {
            try await api.setModel(scope: "auxiliary", provider: provider, model: model, task: task, baseURL: baseURL)
            AppLog.trace("settings", "auxiliary model \(task) set in \(AppLog.ms(since: start)) ms")
            await load()
            return nil
        } catch {
            AppLog.note("settings", "auxiliary model \(task) set failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            return SettingsErrorText.save(error)
        }
    }
}

struct AuxiliaryModelsView: View {
    let router: SettingsRouter
    /// A bot's own helper models (`?profile=`): the footer says whose they are. Nil: the default profile's.
    var botName: String? = nil
    @State private var model: AuxiliaryModel
    @State private var catalog: ModelCatalogModel
    @State private var failure: String?
    /// The assignment that failed, for Try Again (UX #201).
    @State private var lastAttempt: (() -> Void)?

    /// `profile`: a bot's own (its assignments, its catalog, its Main Model for "Use Main Model"); nil, the default's.
    init(router: SettingsRouter, profile: String? = nil, botName: String? = nil) {
        self.router = router
        self.botName = botName
        let shared = router.gatewaySettings?.settingsAPI
        let api = profile.flatMap { profile in shared.map { GatewaySettingsAPI(client: $0.client, profile: profile) } } ?? shared
        _model = State(initialValue: AuxiliaryModel(api: api, readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false))
        _catalog = State(initialValue: ModelCatalogModel(api: api))
    }

    var body: some View {
        List { Group {
            if let failure {
                SaveFailureSection(text: failure, detail: nil, retry: lastAttempt.map { again in { self.failure = nil; lastAttempt = nil; again() } },
                                   dismiss: { self.failure = nil; lastAttempt = nil })
            }
            if let error = model.error, !model.loaded {
                LoadFailureSection(title: "Couldn’t Load Auxiliary Models", text: error) { Task { await model.load() } }
            } else if !model.loaded {
                LoadingSection()
            } else {
                Section {
                    ForEach(model.tasks) { task in
                        ChooserRow(title: AuxiliaryAssignment.title(task.task),   // [mac] #51: a pop-up button on the Mac
                                   value: model.busy == task.task ? "Saving…" : task.followsMain ? "Main Model"
                                    : catalog.describe(provider: task.provider, model: task.model)) {
                            choose(task)
                        }
                        .accessibilityIdentifier("aux-task.\(task.task)")
                    }
                } footer: { HQSectionFooter {
                    Text(SettingsWords.botScoped("Helper jobs (reading images, summarizing long chats, naming chats…) can use a cheaper or faster model than your main one.",
                                                 bot: botName, defaultBot: router.defaultBotName, otherBots: router.hasOtherBots))   // [model-scope]
                        .accessibilityIdentifier("aux.footer")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(failure)
        .task {
            await model.load()
            await catalog.load()
        }
        .accessibilityIdentifier("aux.list")
    }

    private func choose(_ task: AuxiliaryAssignment) {
        let view = AuxiliaryTaskView(task: task, catalog: catalog, note: router.modelScope(bot: botName)) { provider, model in   // [model-scope]
            router.closeChooser()
            assign(task.task, provider: provider, model: model)
        }
        router.openChooser(AuxiliaryAssignment.title(task.task), view)   // [mac] Stress test 2026-10-28 #51: a sheet on the Mac
    }

    private func assign(_ task: String, provider: String, model: String) {
        Task {
            if let error = await self.model.set(task, provider: provider, model: model, baseURL: catalog.provider(provider)?.apiURL) {
                failure = error
                lastAttempt = { assign(task, provider: provider, model: model) }
            } else {
                Haptics.play(.success)
            }
        }
    }
}

struct AuxiliaryTaskView: View {
    let task: AuxiliaryAssignment
    let catalog: ModelCatalogModel
    /// [model-scope] Whose helper model this is, under the chooser's provider.
    var note: String? = nil
    let pick: (_ provider: String, _ model: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List { Group {
                Section {
                    Button {
                        pick(catalog.mainProvider, catalog.mainModel)
                    } label: {
                        HQOptionRowLabel(title: "Use Main Model", selected: task.followsMain)   // [mac] Stress test 2026-10-28 #51: a leading radio on the Mac
                    }
                    .disabled(catalog.mainModel.isEmpty)
                    .accessibilityIdentifier("aux.use-main")
                } footer: { HQSectionFooter {
                    Text("Or pick a model for this job below.")
                } }
            }.hqMacSettingsRowInsets() }
            .settingsList().hqMacSettingsRows()
            .frame(maxHeight: 150)
            ModelChooserView(catalog: catalog, title: "Model", currentProvider: task.followsMain ? "" : task.provider,
                             currentModel: task.followsMain ? "" : task.model, note: note, pick: pick)
        }
        .background(Color.hqGroupedPage)
    }
}

// MARK: - Mixture of Agents

@MainActor @Observable
final class MixtureModel {
    var record: JSONValue?
    var error: String?
    var saveError: String?
    /// The record that failed to save, for Try Again (UX #201); nil when there's nothing to send again.
    var unsaved: JSONValue?
    var saving = false
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool

    init(api: GatewaySettingsAPI?, readOnly: Bool) {
        self.api = api
        self.readOnly = readOnly
    }

    var presetNames: [String] { (record?["presets"]?.object ?? [:]).keys.sorted() }
    var defaultPreset: String { record?["default_preset"]?.string ?? presetNames.first ?? "" }

    func preset(_ name: String) -> JSONValue? { record?["presets"]?[name] }

    func load() async {
        guard let api else { return }
        do {
            record = try await api.moa()
            error = nil
        } catch {
            AppLog.note("settings", "mixture of agents load failed: \(type(of: error))")
            self.error = SettingsErrorText.load(error)
        }
    }

    /// Every slot of every preset has a provider and a model: the only state the gateway accepts (`moaConfigComplete`).
    static func complete(_ record: JSONValue) -> Bool {
        (record["presets"]?.object ?? [:]).values.allSatisfy { preset in
            let refs = preset["reference_models"]?.array ?? []
            func done(_ slot: JSONValue?) -> Bool {
                !(slot?["provider"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    && !(slot?["model"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            return !refs.isEmpty && refs.allSatisfy(done) && done(preset["aggregator"])
        }
    }

    /// Changes one preset, mirrors the default preset onto the top level (as the gateway serves it), and saves the whole
    /// record (`PUT /api/model/moa`) once it is complete.
    func edit(_ name: String, _ change: (inout [String: JSONValue]) -> Void) {
        guard var record, var preset = record["presets"]?[name]?.object else { return }
        change(&preset)
        record = ConfigPath.set(record, "presets.\(name)", .object(preset))
        if name == defaultPreset {
            for key in ["aggregator", "aggregator_temperature", "reference_models", "reference_temperature", "enabled"] {
                if let value = preset[key] { record = ConfigPath.set(record, key, value) }
            }
        }
        self.record = record
        save()
    }

    func setDefault(_ name: String) {
        guard var record, let preset = record["presets"]?[name] else { return }
        record = ConfigPath.set(record, "default_preset", .string(name))
        record = ConfigPath.set(record, "active_preset", .string(name))
        for key in ["aggregator", "aggregator_temperature", "reference_models", "reference_temperature", "enabled"] {
            if let value = preset[key] { record = ConfigPath.set(record, key, value) }
        }
        self.record = record
        save()
    }

    private func save() {
        guard let record, Self.complete(record), let api else { return }
        if readOnly { saveError = BotWriteError.readOnlyReason; unsaved = nil; return }
        saving = true
        let start = ContinuousClock.now
        Task {
            defer { saving = false }
            do {
                let saved = try await api.saveMoa(record)
                if saved["presets"] != nil { self.record = saved }
                saveError = nil
                unsaved = nil
                AppLog.trace("settings", "mixture of agents saved in \(AppLog.ms(since: start)) ms")
            } catch {
                AppLog.note("settings", "mixture of agents save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                saveError = SettingsErrorText.save(error)
                unsaved = record
                await load()
            }
        }
    }

    /// Try Again: the record that failed, sent again.
    func retry() {
        guard let unsaved else { return }
        saveError = nil
        self.unsaved = nil
        record = unsaved
        save()
    }
}

struct MixtureOfAgentsView: View {
    let router: SettingsRouter
    @State private var model: MixtureModel
    @State private var catalog: ModelCatalogModel
    @State private var selected = ""
    /// [mac] The reference model picked for − (Mac polish #40, as Fallback Models' rows).
    @State private var pickedModel: Int?

    init(router: SettingsRouter) {
        self.router = router
        let api = router.gatewaySettings?.settingsAPI
        _model = State(initialValue: MixtureModel(api: api, readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false))
        _catalog = State(initialValue: ModelCatalogModel(api: api))
    }

    var body: some View {
        List { Group {
            if let error = model.saveError {
                SaveFailureSection(text: error, detail: nil, retry: model.unsaved == nil ? nil : { model.retry() },
                                   dismiss: { model.saveError = nil; model.unsaved = nil })
            }
            if let error = model.error, model.record == nil {
                LoadFailureSection(title: "Couldn’t Load Mixture of Agents", text: error) { Task { await model.load() } }
            } else if model.record == nil {
                LoadingSection()
            } else {
                let name = selected.isEmpty ? model.defaultPreset : selected
                // Stress test 2026-10-28 #83 (both): the switch comes first and the rows it governs (the models, Add Model,
                // Aggregator) are dimmed while it is off. Preset stays live: the switch is that preset's own `enabled`, so the
                // picker chooses which preset's switch is shown. The saved record is unchanged.
                let on = model.preset(name)?["enabled"]?.bool ?? false
                // Stress test 2026-10-28 #83, round 2 (both): `.disabled` alone left Model 1/2 and Aggregator at full
                // strength, because `ValueRow` paints its title and value in fixed colours that ignore the disabled
                // state (only Add Model…, a plain Label, dimmed). The rows the switch governs are now faded as well.
                // Preset is held too while Hermes's own preset is off; a preset picked away from Hermes's one stays
                // pickable, so the way back is never locked.
                // [mac] Stress test 2026-10-28 round 7: on the Mac the rows dim themselves while disabled (labels and
                // pop-ups in the secondary label colour, about 3:1 or better); 45 % opacity left them at about 1.5:1.
                let dim: Double = on || DeviceWord.isMac ? 1 : 0.45
                let presetHeld = !on && name == model.defaultPreset
                if let preset = model.preset(name) {
                    Section {
                        SwitchRow(title: "Mixture of Agents", isOn: Binding(
                            get: { preset["enabled"]?.bool ?? false },
                            set: { on in model.edit(name) { $0["enabled"] = .bool(on) } }))
                            .accessibilityIdentifier("moa.enabled")
                    } footer: { HQSectionFooter {
                        // [model-scope] Owner 2026-11-03: the default profile's presets (`/api/model/moa`); no other bot has this page.
                        Text(SettingsWords.moaFooter(defaultBot: router.defaultBotName))
                            .accessibilityIdentifier("moa.footer")
                    } }
                    if model.presetNames.count > 1 {
                        Section {
                            presetPicker(name)
                            .accessibilityIdentifier("moa.preset")
                            .disabled(presetHeld)
                            .opacity(presetHeld && !DeviceWord.isMac ? 0.45 : 1)   // [mac] Stress test 2026-10-28 round 7: the Mac row dims itself
                            if name != model.defaultPreset {
                                Button("Use This Preset") { model.setDefault(name) }
                            }
                        } footer: { HQSectionFooter {
                            Text(presetHeld ? "Turn on Mixture of Agents to choose a preset."
                                 : name == model.defaultPreset ? "Hermes uses this preset’s models below."
                                                             : "Hermes uses \(ConfigText.pretty(model.defaultPreset)). Use This Preset to switch to \(ConfigText.pretty(name)).")
                        } }
                    }
                    Section {
                        let refs = preset["reference_models"]?.array ?? []
                        ForEach(Array(refs.enumerated()), id: \.offset) { index, slot in
                            ChooserRow(title: "Model \(index + 1)",   // [mac] #51: a pop-up button on the Mac
                                       value: catalog.describe(provider: slot["provider"]?.string ?? "", model: slot["model"]?.string ?? "")) {
                                chooseSlot(name, title: "Model \(index + 1)", slot: slot) { provider, picked in
                                    model.edit(name) { preset in
                                        var list = preset["reference_models"]?.array ?? []
                                        guard index < list.count else { return }
                                        list[index] = ConfigPath.set(ConfigPath.set(list[index], "provider", .string(provider)), "model", .string(picked))
                                        preset["reference_models"] = .array(list)
                                    }
                                }
                            }
                            .opacity(dim)
                            .accessibilityIdentifier("moa.ref-\(index)")
                            // [mac] Mac polish #40 (owner 2026-11-07): a click beside the pop-up picks the row for −,
                            // as Fallback Models' rows are picked.
                            .contentShape(Rectangle())
                            .listRowBackground(DeviceWord.isMac && pickedModel == index ? Color.hqTint.opacity(0.18) : nil)
                            .onTapGesture { if DeviceWord.isMac { pickedModel = index } }
                            // [mac] A mouse has no swipe: Remove on a right-click (and a touch and hold).
                            .contextMenu {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) { removeModel(name, at: index) }
                            }
                        }
                        .onDelete { offsets in
                            model.edit(name) { preset in
                                var list = preset["reference_models"]?.array ?? []
                                list.remove(atOffsets: offsets)
                                preset["reference_models"] = .array(list)
                            }
                        }
                        if DeviceWord.isMac {
                            // [mac] Mac polish #40 (owner 2026-11-07): + and − under the list, as Fallback Models has
                            // and as the Mac's own System Settings lists do, in place of an Add Model… row.
                            HStack(spacing: 0) {
                                MacAddRemoveButtons(addLabel: "Add Reference Model", removeLabel: "Remove Reference Model",
                                                    addHelp: "Add Reference Model…", removeHelp: "Remove the Selected Model",
                                                    canRemove: pickedModel.map { refs.indices.contains($0) } ?? false,
                                                    add: { addModel(name) },
                                                    remove: { if let pickedModel { removeModel(name, at: pickedModel) } },
                                                    addIdentifier: "moa.add", removeIdentifier: "moa.remove")
                                Spacer(minLength: 0)
                            }
                        } else {
                        Button {
                            addModel(name)
                        } label: {
                            // Stress test 2026-10-28 round 6 (both): the + kept the full accent while the section was
                            // dimmed (the disabled title went grey, the icon didn't); it dims with its title now.
                            Label {
                                Text("Add Model…")
                            } icon: {
                                Image(systemName: "plus")
                                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.hqLabel3))
                            }
                        }
                        .accessibilityIdentifier("moa.add")
                        }
                    } header: { HQSectionLabel {
                        Text("Reference Models")
                    } } footer: {
                        if DeviceWord.isMac, !(preset["reference_models"]?.array ?? []).isEmpty {
                            HQSectionFooter { Text("Click beside a model, then − to remove it.") }
                        }
                    }
                    .disabled(!on)
                    Section {
                        let slot = preset["aggregator"]
                        ChooserRow(title: "Aggregator", value: catalog.describe(provider: slot?["provider"]?.string ?? "", model: slot?["model"]?.string ?? "")) {
                            chooseSlot(name, title: "Aggregator", slot: slot) { provider, picked in
                                model.edit(name) { preset in
                                    let current = preset["aggregator"] ?? .object([:])
                                    preset["aggregator"] = ConfigPath.set(ConfigPath.set(current, "provider", .string(provider)), "model", .string(picked))
                                }
                            }
                        }
                        .opacity(dim)
                        .accessibilityIdentifier("moa.aggregator")
                    } footer: { HQSectionFooter {
                        Text(model.saving ? "Saving…" : "Changes save by themselves once every model is chosen.")
                    } }
                    .disabled(!on)
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.saveError)
        .task {
            await model.load()
            await catalog.load()
        }
        .accessibilityIdentifier("moa.list")
    }

    /// [mac] Stress test 2026-10-28 round 6: on the Mac the Preset is a form row, its pop-up in the control column under
    /// Model 1/2 and Aggregator's (a menu picker trailed the row, and dimmed its "Balanced" was nearly invisible in the
    /// Desktop Look dark). Elsewhere the menu picker as before.
    @ViewBuilder private func presetPicker(_ name: String) -> some View {
        let selection = Binding(get: { name }, set: { selected = $0; pickedModel = nil })   // [mac] − forgets the other preset's row
        if DeviceWord.isMac {
            MacFormRow(label: "Preset") {
                MacPopUp(label: "Preset", selection: selection, options: model.presetNames) { ConfigText.pretty($0) }
            }
        } else {
            Picker("Preset", selection: selection) {
                ForEach(model.presetNames, id: \.self) { Text(ConfigText.pretty($0)).tag($0) }
            }
            .hqMenuPicker()
        }
    }

    /// A reference model for `name`, chosen in the model sheet.
    private func addModel(_ name: String) {
        chooseSlot(name, title: "Add Model", slot: nil) { provider, picked in
            model.edit(name) { preset in
                var list = preset["reference_models"]?.array ?? []
                list.append(["provider": .string(provider), "model": .string(picked)])
                preset["reference_models"] = .array(list)
            }
        }
    }

    private func removeModel(_ name: String, at index: Int) {
        var left = 0
        model.edit(name) { preset in
            var list = preset["reference_models"]?.array ?? []
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            preset["reference_models"] = .array(list)
            left = list.count
        }
        pickedModel = left == 0 ? nil : min(index, left - 1)
    }

    private func chooseSlot(_ preset: String, title: String, slot: JSONValue?, done: @escaping (String, String) -> Void) {
        let view = ModelChooserView(catalog: catalog, title: title, currentProvider: slot?["provider"]?.string ?? "",
                                    currentModel: slot?["model"]?.string ?? "", excludeMoa: true,
                                    note: SettingsWords.appliesOnly(to: router.defaultBotName)) { provider, model in   // [model-scope]
            router.closeChooser()
            done(provider, model)
        }
        router.openChooser(title, view)   // [mac] Stress test 2026-10-28 #51: a sheet on the Mac
    }
}
