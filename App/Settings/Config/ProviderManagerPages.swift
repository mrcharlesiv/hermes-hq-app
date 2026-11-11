// [provider-manager] Owner 2026-11-05: "I don't know, you tell me where I can do it. I just need to be able to like add
// and remove providers and then edit their names and then edit the list of models on each provider so that I can like
// control which ones show in the app and the names and everything else."
//
// Settings › Providers is one list of the providers you have (`ProviderList.merge`: your own endpoints, Hermes' built-in
// providers with a key saved, the accounts you're signed in to), each with its name, what it is, and how many of its
// models show. + adds one (Add Provider). Swipe a row (or touch and hold / Control-click it) to remove it, after one
// confirm: an endpoint is deleted, a key removed, an account signed out; where Hermes can't, it says why.
//
// A provider's page: Name (your own endpoints are renamed on the gateway; a built-in's or an account's name is the app's,
// synced to your other devices), Models (every model it offers, a Show switch each, tap a name to rename it, Show All /
// Hide All, Add Model…), Default Model, its key (or connection), Test Connection for your own, and Remove Provider.
// What is hidden or renamed applies to every model menu in the app (`ProviderPrefs`); a pick still sends the real ids.

import Observation
import SwiftUI
import UIKit

// MARK: - The page's data

@MainActor @Observable
final class ProvidersModel {
    let env: EnvKeysModel
    let custom: CustomProvidersModel
    let catalog: ModelCatalogModel
    var accounts: [OAuthProviderRow] = []
    var accountsError: String?
    var accountsLoaded = false
    /// The account's names and short lists (kept up to date when another page or device changes them).
    var prefs: ProviderPrefs
    /// A remove from the list (or the page) that failed.
    var failure: String?
    /// The provider being removed (its row shows it).
    var removing: String?
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool
    @ObservationIgnored let account: String?
    @ObservationIgnored private var watch: NSObjectProtocol?

    init(router: SettingsRouter) {
        let api = router.gatewaySettings?.settingsAPI
        let readOnly = router.gatewaySettings?.isReadOnlyGateway ?? false
        let account = router.services.account?.id
        self.api = api
        self.readOnly = readOnly
        self.account = account
        env = EnvKeysModel(api: api, readOnly: readOnly)
        custom = CustomProvidersModel(api: api, readOnly: readOnly, account: account)
        catalog = ModelCatalogModel(api: api)
        prefs = Self.store(account)?.prefs ?? ProviderPrefs.active
        watch = NotificationCenter.default.addObserver(forName: ProviderPrefsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPrefs() }
        }
    }

    isolated deinit { if let watch { NotificationCenter.default.removeObserver(watch) } }

    private static func store(_ account: String?) -> ProviderPrefsStore? {
        if let current = ProviderPrefsStore.current { return current }
        return account.map { ProviderPrefsStore.of(accountId: $0) }
    }

    private func reloadPrefs() { prefs = Self.store(account)?.prefs ?? ProviderPrefs.active }

    /// Changes the names or short lists: saved, synced, and every model menu shows them from its next open.
    func update(_ change: (inout ProviderPrefs) -> Void) {
        guard let store = Self.store(account) else { return }
        store.update(change)
        prefs = store.prefs
        if let account { ModelCatalogCache.shared.markStale(account: account) }
    }

    var rows: [ManagedProvider] {
        ProviderList.merge(custom: custom.providers, vars: env.vars, accounts: accounts, catalog: catalog.raw, prefs: prefs)
    }

    func row(_ id: String) -> ManagedProvider? { rows.first { $0.id == id } }

    var loaded: Bool { env.loaded && custom.loaded && accountsLoaded }

    /// The keys and your own endpoints have loaded, and the sign-ins have loaded or failed: the list can show (a failed
    /// sign-in list says so under it instead of standing in for the whole page).
    var listReady: Bool { env.loaded && custom.loaded && (accountsLoaded || accountsError != nil) }

    /// Everything the list needs, read at once.
    func load() async {
        async let keys: Void = env.load()
        async let mine: Void = custom.load()
        async let models: Void = catalog.load()
        async let signIns: Void = loadAccounts()
        _ = await (keys, mine, models, signIns)
    }

    func loadAccounts() async {
        guard let api else { return }
        do { accounts = try await api.oauthProviders(); accountsError = nil; accountsLoaded = true } catch {
            AppLog.note("settings", "provider accounts load failed: \(type(of: error))")
            accountsError = SettingsErrorText.load(error)
        }
    }

    /// The model catalog's own provider row for a provider (its real slug, models, key and address).
    func catalogRow(_ id: String) -> ModelProviderOption? { catalog.raw.first { ProviderPrefs.providerKey($0.slug) == id } }

    // MARK: Remove

    /// Remove, after one confirm (or the reason it can't be). `done` runs once it is gone.
    func askRemove(_ row: ManagedProvider, router: SettingsRouter, done: @escaping () -> Void = {}) {
        let name = row.name(prefs)
        switch row.removal {
        case .cannot(let reason):
            Haptics.play(.warning)
            let alert = UIAlertController(title: "Can’t Remove \(name)", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            FailureAlert.topmost(router.presenter)?.present(alert, animated: true)
        case .deleteEndpoint:
            guard let endpoint = row.endpoint else { return }
            CustomProviderPages.confirmDelete(endpoint, model: custom, from: router.presenter, started: { [weak self] in
                self?.removing = row.id
            }) { [weak self] failure in
                self?.removing = nil
                self?.failure = failure
                if failure == nil { done() }
            }
        case .removeKeys(let keys), .removeKeysAndSignOut(let keys):
            let signOut = row.removal != .removeKeys(keys)
            let message = signOut
                ? "Its key is removed from \(HostWord.phrase) and Hermes signs out of it there. Bots that use \(name) stop working until you add it again."
                : "Its key is removed from \(HostWord.phrase). Bots that use \(name) stop working until you add it again."
            TextPrompt.confirm(title: "Remove \(name)?", message: message, action: "Remove", from: router.presenter) { [weak self] in
                Task { await self?.remove(row, keys: keys, signOut: signOut, done: done) }
            }
        case .signOut:
            TextPrompt.confirm(title: "Sign Out of \(name)?",
                               message: "Hermes on \(HostWord.phrase) forgets this sign-in. Bots that use \(name) stop working until you sign in again there.",
                               action: "Sign Out", from: router.presenter) { [weak self] in
                Task { await self?.remove(row, keys: [], signOut: true, done: done) }
            }
        }
    }

    /// A provider no longer in the list loses the names, hidden models and added models kept for it, so adding it again
    /// later starts fresh. (Your own endpoints' are forgotten by `CustomProvidersModel.delete`.)
    private func forgetIfGone(_ id: String) {
        guard row(id) == nil else { return }
        update { $0.forget(provider: id) }
        // [ghost-stars] Its starred models leave the Switch Model menus now, not after each chat's next catalog read.
        if let account { ModelPrefs(accountId: account).removeKnownProvider(id) }
    }

    private func remove(_ row: ManagedProvider, keys: [String], signOut: Bool, done: () -> Void) async {
        removing = row.id
        failure = nil
        defer { removing = nil }
        for key in keys {
            guard await env.remove(key) else {
                failure = env.failure ?? "Couldn’t remove the key."
                env.dismissFailure()
                Haptics.play(.error)
                return
            }
        }
        if signOut, let account = row.account, let api {
            do {
                try await api.signOutOAuthProvider(account.id)
                AppLog.note("settings", "provider signed out: \(account.id)")
            } catch {
                AppLog.note("settings", "provider sign out failed: \(type(of: error))")
                failure = SettingsErrorText.save(error)
                Haptics.play(.error)
                await loadAccounts()
                return
            }
            await loadAccounts()
        }
        AppLog.note("settings", "provider removed: \(row.id) (\(keys.count) keys\(signOut ? ", signed out" : ""))")
        Haptics.play(.success)
        if let account { ModelCatalogCache.shared.markStale(account: account) }
        await catalog.load()
        forgetIfGone(row.id)
        done()
    }
}

// MARK: - Settings › Providers

struct ProvidersPageView: View {
    let router: SettingsRouter
    @State private var model: ProvidersModel
    /// [provider-add] Opened from the model list's Add Provider…: the chooser goes over it once it shows.
    private let startAdding: Bool
    @State private var startedAdding = false

    init(router: SettingsRouter, startAdding: Bool = false) {
        self.router = router
        self.startAdding = startAdding
        _model = State(initialValue: ProvidersModel(router: router))
    }

    var body: some View {
        let rows = model.rows
        let prefs = model.prefs
        List { Group {
            if let failure = model.failure ?? model.custom.listFailure {
                SaveFailureSection(text: failure, detail: nil, retry: nil, dismiss: { model.failure = nil; model.custom.listFailure = nil })
            }
            if !model.listReady, rows.isEmpty, let error = model.env.loadError ?? model.custom.loadError {
                LoadFailureSection(title: "Couldn’t Load Providers", text: error) { Task { await model.load() } }
            } else if !model.listReady, rows.isEmpty {
                LoadingSection()
            } else {
                Section {
                    if rows.isEmpty {
                        Text("No providers yet. \(DeviceWord.Tap) + to add one.")
                            .foregroundStyle(Color.hqLabel2)
                            .hqRowPadding(4)
                            .accessibilityIdentifier("providers.empty")
                    }
                    ForEach(rows) { row in
                        ProviderListRow(row: row, prefs: prefs, catalog: model.catalog.raw, removing: model.removing == row.id,
                                        readOnly: model.readOnly) {
                            ProviderPages.open(row.id, model: model, router: router)
                        } rename: {
                            ProviderPages.rename(row, model: model, router: router)
                        } remove: {
                            model.askRemove(row, router: router)
                        }
                    }
                    if !model.readOnly {
                        Button(action: openAdd) {
                            if DeviceWord.isMac {
                                MacAddRowLabel(title: "Add Provider…")
                            } else {
                                Label("Add Provider…", systemImage: "plus")
                            }
                        }
                        .hqRowPadding(4)
                        .accessibilityIdentifier("custom-providers.add")
                    }
                } footer: { HQSectionFooter {
                    Text(footer)
                } }
                // The accounts Hermes is signed in to are missing from the list above until this reads.
                if let error = model.accountsError {
                    LoadFailureSection(title: "Couldn’t Load Your Sign-Ins", text: error) { Task { await model.loadAccounts() } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.failure)
        .task { await model.load() }
        .refreshable { await model.load() }
        // [provider-add] Owner 2026-11-04 ("more easily add them"): + opens Add Provider, at the top of the page.
        .toolbar {
            if !model.readOnly {
                ToolbarItem(placement: .primaryAction) {
                    let _ = Theme.touch()
                    Button(action: openAdd) { Image(systemName: "plus") }
                        .accessibilityLabel(ProviderAdd.title)
                        .accessibilityIdentifier("providers.add")
                }
                // The Desktop Look's bar items are plain glyphs (the shared glass circle behind a SwiftUI item showed,
                // beside a flat Back; StarMapPage's filter had the same). [mac] Mac polish #67: the Mac's iOS look's too
                // (`DesktopBars.macPlain`), which SwiftUI's own setting here outranked.
                .sharedBackgroundVisibility(Theme.isDesktop || DeviceWord.isMac ? .hidden : .automatic)
            }
        }
        .onAppear {
            guard startAdding, !startedAdding else { return }
            startedAdding = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))   // after the push that showed this page has settled
                openAdd()
            }
        }
        .accessibilityIdentifier("providers.list")
    }

    private var footer: String {
        let how = DeviceWord.isMac
            ? "Click one to rename it or choose which of its models show. \(DeviceWord.hold) one to remove it."   // Mac polish #135
            : "Tap one to rename it or choose which of its models show. Swipe one to remove it."
        return "The providers your bots can use. \(how) More services are under +."
    }

    private func openAdd() {
        ProviderAdd.openChooser(env: model.env, custom: model.custom, router: router)
    }
}

/// One provider in the list: its name, what it is, how many models show.
private struct ProviderListRow: View {
    let row: ManagedProvider
    let prefs: ProviderPrefs
    let catalog: [ModelProviderOption]
    let removing: Bool
    let readOnly: Bool
    let open: () -> Void
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: open) {
            // [provider-rows] Owner 2026-11-10 (design pick 4): two lines a row. How many models show stands at the
            // trailing edge of the name's line (it was a third line), and a dot leads the second line: green, or
            // orange with an orange "No models" when the provider has nothing to pick from.
            let edge = ProviderList.shownEdge(row, catalog: catalog, prefs: prefs)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.name(prefs)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(removing ? "Removing…" : edge.text)
                            .font(Font.hq(.footnote)).monospacedDigit()
                            .foregroundStyle(edge.none && !removing ? Color.hqOrange : Color.hqLabel2)
                            .lineLimit(1).fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(edge.none ? Color.hqOrange : Color(uiColor: .systemGreen))
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                            .accessibilityHidden(true)
                        Text(row.endpoint?.isCurrent == true ? "\(row.sourceLine) · Default" : row.sourceLine)
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                    }
                }
                SettingsChevron()
            }
            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        // The words as before the edge: "Anthropic, Built into Hermes · Key saved, 4 models shown".
        .accessibilityLabel([row.name(prefs), row.sourceLine, row.endpoint?.isCurrent == true ? "Default" : nil,
                             removing ? "Removing…" : ProviderList.shownLine(row, catalog: catalog, prefs: prefs)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("provider.\(row.id)")
        // Red, not the destructive role, which animates the row out before the confirm (GatewayPageView's rows). A row
        // that can't be removed still offers Remove, which says why.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !readOnly, !removing { Button(removeWord) { remove() }.tint(.red) }
        }
        // A mouse has no swipe: the same on a right-click (and a touch and hold).
        .contextMenu {
            if !readOnly {
                Button("Rename…", systemImage: "pencil") { rename() }
                    .accessibilityIdentifier("provider.menu-rename")
                Button("\(removeWord)…", systemImage: removeIcon, role: .destructive) { remove() }
                    .accessibilityIdentifier("provider.menu-remove")
            }
        }
    }

    private var removeWord: String { row.removal == .signOut ? "Sign Out" : "Remove" }
    private var removeIcon: String { row.removal == .signOut ? "rectangle.portrait.and.arrow.right" : "trash" }
}

// MARK: - Pushes and prompts

@MainActor enum ProviderPages {
    static func open(_ id: String, model: ProvidersModel, router: SettingsRouter) {
        guard let row = model.row(id) else { return }
        router.push(row.name(model.prefs), ProviderPageView(id: id, model: model, router: router))
    }

    /// Rename: on the gateway for one of your own (its id kept), else the app's own name, with Reset to Original.
    /// `onPage`: asked from the provider's own page, whose title follows the name (not from the list's row menu).
    static func rename(_ row: ManagedProvider, model: ProvidersModel, router: SettingsRouter, onPage: Bool = false) {
        func retitle(_ name: String) { if onPage { router.navigation?.topViewController?.title = name } }
        let current = row.name(model.prefs)
        let renamed = row.endpoint == nil && model.prefs.providerName(row.id) != nil
        let message = row.endpoint != nil
            ? "Saved on \(HostWord.phrase), so the Hermes desktop app shows it too."
            : "Shown in Hermes HQ on all your devices. Hermes itself keeps calling it \(row.originalName)."
        TextPrompt.present(title: "Rename Provider", message: message, text: current, placeholder: row.originalName, action: "Rename",
                           maxLength: 60, requireChange: true, identifier: "provider.rename-field", selectText: true,
                           secondary: renamed ? ("Reset to Original", {
                               model.update { $0.setProviderName(nil, provider: row.id) }
                               retitle(row.originalName)
                               Haptics.play(.success)
                           }) : nil,
                           from: router.presenter) { name in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if let endpoint = row.endpoint {
                Task {
                    do {
                        try await model.custom.rename(endpoint, to: name)
                        Haptics.play(.success)
                        retitle(name)
                    } catch {
                        AppLog.note("settings", "custom provider rename failed: \(type(of: error))")
                        model.failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                        Haptics.play(.error)
                    }
                }
            } else {
                model.update { $0.setProviderName(name, provider: row.id, original: row.originalName) }
                retitle(name)
                AppLog.note("settings", "provider renamed in the app: \(row.id)")
                Haptics.play(.success)
            }
        }
    }

    /// A model's name, with Reset to Original once renamed.
    static func renameModel(_ id: String, provider: ManagedProvider, model: ProvidersModel, router: SettingsRouter) {
        let original = ModelNames.builtInModelName(id)
        let own = model.prefs.modelName(provider: provider.id, model: id)
        TextPrompt.present(title: "Rename Model", message: "The model’s ID stays \(id). Only Hermes HQ shows the new name.",
                           text: own ?? original, placeholder: original, action: "Rename", maxLength: 80, requireChange: true,
                           identifier: "provider-model.rename-field", selectText: true,
                           secondary: own != nil ? ("Reset to Original", {
                               model.update { $0.setModelName(nil, provider: provider.id, model: id) }
                               Haptics.play(.success)
                           }) : nil,
                           from: router.presenter) { name in
            model.update { $0.setModelName(name, provider: provider.id, model: id, original: original) }
            AppLog.note("settings", "model renamed in the app (\(provider.id))")
            Haptics.play(.success)
        }
    }
}

// MARK: - A provider's page

struct ProviderPageView: View {
    let id: String
    let model: ProvidersModel
    let router: SettingsRouter
    /// What Test Connection found (your own endpoints).
    @State private var found: [String] = []
    @State private var test: CustomProviderTest?
    @State private var testing = false
    @State private var busy = false
    @State private var query = ""
    @State private var failure: String?
    /// The last row seen: the page keeps it while the list reads again after a change (it never goes blank).
    @State private var last: ManagedProvider?

    /// Your own endpoint, deleted since the page showed it (its Address, Key and Connection page's Delete Provider): the
    /// page says so instead of keeping the last copy.
    private var endpointDeleted: Bool {
        guard let endpoint = last?.endpoint, model.custom.loaded else { return false }
        return model.custom.provider(endpoint.id) == nil
    }

    var body: some View {
        let row = model.row(id) ?? (endpointDeleted ? nil : last)
        List { Group {
            if let failure = failure ?? model.failure {
                SaveFailureSection(text: failure, detail: nil, retry: nil, dismiss: { self.failure = nil; model.failure = nil })
            }
            if let row {
                nameSection(row)
                modelsSection(row)
                defaultSection(row)
                keySection(row)
                removeSection(row)
            } else {
                Section { Text("This provider was removed.").foregroundStyle(Color.hqLabel2) }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(failure)
        .onChange(of: model.row(id)) { _, now in if let now { last = now } }
        .onAppear { if last == nil { last = model.row(id) } }
        .refreshable { await model.load() }
        .accessibilityIdentifier("provider-page")
    }

    private var prefs: ProviderPrefs { model.prefs }
    private var locked: Bool { model.readOnly || busy }

    // MARK: Name

    private func nameSection(_ row: ManagedProvider) -> some View {
        Section {
            ValueRow(title: "Name", value: row.name(prefs), opensPrompt: true) { ProviderPages.rename(row, model: model, router: router, onPage: true) }
                .disabled(model.readOnly)
                .accessibilityIdentifier("provider-page.name")
        } footer: { HQSectionFooter {
            if row.endpoint != nil {
                Text("Saved on \(HostWord.phrase), so the Hermes desktop app shows the same name.")
            } else if prefs.providerName(row.id) != nil {
                Text("Hermes calls it \(row.originalName). The new name shows in Hermes HQ on all your devices.")
            } else {
                Text("The name shows in every model menu in Hermes HQ, on all your devices.")
            }
        } }
    }

    // MARK: Models

    private func modelsSection(_ row: ManagedProvider) -> some View {
        let all = ProviderList.allModels(row, catalog: model.catalog.raw, found: found, prefs: prefs)
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = words.isEmpty ? all : all.filter { id in
            id.lowercased().contains(words) || name(id, row).lowercased().contains(words)
        }
        let anyHidden = all.contains { prefs.isHidden(provider: row.id, model: $0) }
        let anyShown = all.contains { !prefs.isHidden(provider: row.id, model: $0) }
        return Section {
            if all.count > 12 {
                TextField("Search Models", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .hqRowPadding(4)
                    .accessibilityIdentifier("provider-models.search")
            }
            // [provider-models] Owner 2026-11-10 (design pick 20): on the iPhone and iPad, Show All and Hide All sit on
            // the Models heading's line (as the list's first row they read as a model); the Mac keeps the row.
            if all.count > 1, DeviceWord.isMac {
                HStack(spacing: 20) {
                    Button("Show All") { setAll(all, hide: false, row) }
                        .disabled(!anyHidden || model.readOnly)
                        .accessibilityIdentifier("provider-models.show-all")
                    Button("Hide All") { setAll(all, hide: true, row) }
                        .disabled(!anyShown || model.readOnly)
                        .accessibilityIdentifier("provider-models.hide-all")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .hqRowPadding(4)
            }
            if all.isEmpty {
                Text(row.endpoint != nil ? "No models saved yet. Use Test Connection below, or Add Model…" : "Hermes lists no models for this provider yet.")
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hqRowPadding(4)
            }
            ForEach(shown, id: \.self) { id in modelRow(id, row) }
            if !model.readOnly {
                Button { addModel(row) } label: {
                    if DeviceWord.isMac { MacAddRowLabel(title: "Add Model…") } else { Label("Add Model…", systemImage: "plus") }
                }
                .disabled(locked)
                .hqRowPadding(4)
                .accessibilityIdentifier("provider-models.add")
            }
        } header: { HQSectionLabel {
            if all.count > 1, !DeviceWord.isMac {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Models")
                    Spacer(minLength: 8)
                    Button("Show All") { setAll(all, hide: false, row) }
                        .disabled(!anyHidden || model.readOnly)
                        .accessibilityIdentifier("provider-models.show-all")
                    Button("Hide All") { setAll(all, hide: true, row) }
                        .disabled(!anyShown || model.readOnly)
                        .accessibilityIdentifier("provider-models.hide-all")
                }
                .buttonStyle(.borderless)
                .font(Font.hq(.subheadline))
                .textCase(nil)
            } else {
                Text("Models")
            }
        } } footer: { HQSectionFooter {
            if !words.isEmpty, shown.isEmpty {
                Text("No model matches “\(query)”.")
            } else {
                Text("Switch a model off to leave it out of the model menus; one a bot is using still shows there. \(DeviceWord.Tap) a name to rename it.")
            }
        } }
    }

    private func name(_ id: String, _ row: ManagedProvider) -> String {
        prefs.modelName(provider: row.id, model: id) ?? ModelNames.builtInModelName(id)
    }

    private func modelRow(_ id: String, _ row: ManagedProvider) -> some View {
        let hidden = prefs.isHidden(provider: row.id, model: id)
        let added = prefs.extraModels(row.id).contains(id)
        return HStack(spacing: 12) {
            Button {
                ProviderPages.renameModel(id, provider: row, model: model, router: router)
            } label: {
                let note = [name(id, row) != id ? id : nil, added ? "Added by you" : nil].compactMap { $0 }.joined(separator: " · ")
                // [provider-models] One line a model: its own id beside its name, in small type, when both fit; else
                // the id under the name as before.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name(id, row)).foregroundStyle(hidden ? Color.hqLabel2 : Color.hqLabel).lineLimit(1).fixedSize()
                        if !note.isEmpty {
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(id, row)).foregroundStyle(hidden ? Color.hqLabel2 : Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        if !note.isEmpty {
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.readOnly)
            .accessibilityLabel(name(id, row))
            .accessibilityHint("Renames it")
            .accessibilityIdentifier("provider-model.\(id)")
            Toggle("Show", isOn: Binding(get: { !hidden }, set: { on in
                Haptics.play(.selection)
                model.update { $0.setHidden(!on, provider: row.id, model: id) }
                AppLog.note("settings", "model \(on ? "shown" : "hidden") (\(row.id))")
            }))
            .labelsHidden()
            .disabled(model.readOnly)
            .accessibilityLabel("Show \(name(id, row))")
            .accessibilityIdentifier("provider-model.show.\(id)")
        }
        .hqRowPadding(4)
        .contextMenu {
            if !model.readOnly {
                Button("Rename…", systemImage: "pencil") { ProviderPages.renameModel(id, provider: row, model: model, router: router) }
                if added {
                    Button("Remove Model", systemImage: "trash", role: .destructive) {
                        model.update { $0.removeExtra(id, provider: row.id) }
                    }
                }
            }
        }
    }

    private func setAll(_ models: [String], hide: Bool, _ row: ManagedProvider) {
        Haptics.play(.selection)
        model.update { $0.setHidden(hide, provider: row.id, models: models) }
        AppLog.note("settings", "\(hide ? "hid" : "showed") all \(models.count) models (\(row.id))")
    }

    /// Add Model…: your own endpoint keeps it on the gateway; a built-in's is the app's, offered in the menus.
    private func addModel(_ row: ManagedProvider) {
        let message = row.endpoint != nil
            ? "Type the model’s ID as the service spells it. It’s saved with this provider on \(HostWord.phrase)."
            : "Type the model’s ID as \(row.name(prefs)) spells it. Hermes HQ offers it in the model menus."
        TextPrompt.present(title: "Add Model", message: message, placeholder: "Model ID", action: "Add", maxLength: 200,
                           identifier: "provider-models.add-field", autocapitalization: .none, autocorrection: .no,
                           from: router.presenter) { typed in
            let id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            if let endpoint = row.endpoint {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await model.custom.addModel(id, to: endpoint)
                        model.update { $0.setHidden(false, provider: row.id, model: id) }
                        await model.catalog.load()
                        Haptics.play(.success)
                        AppLog.note("settings", "model added to an endpoint")
                    } catch {
                        AppLog.note("settings", "endpoint add model failed: \(type(of: error))")
                        failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                        Haptics.play(.error)
                    }
                }
            } else {
                model.update { $0.addExtra(id, provider: row.id) }
                AppLog.note("settings", "model added in the app (\(row.id))")
                Haptics.play(.success)
            }
        }
    }

    // MARK: Default Model

    @ViewBuilder private func defaultSection(_ row: ManagedProvider) -> some View {
        if let endpoint = row.endpoint {
            Section {
                ChooserRow(title: "Default Model", value: endpoint.model.isEmpty ? nil : name(endpoint.model, row), alone: true) {
                    let choices = ProviderList.allModels(row, catalog: model.catalog.raw, found: found, prefs: prefs)
                    router.push("Default Model", CustomProviderModelChooser(choices: choices, current: endpoint.model) { picked in
                        router.navigation?.popViewController(animated: true)
                        saveEndpointModel(endpoint, picked)
                    })
                }
                .disabled(locked)
                .accessibilityIdentifier("provider-page.default-model")
            } footer: { HQSectionFooter {
                Text("The model this provider starts with when a bot switches to it.")
            } }
        } else if let catalogRow = model.catalogRow(row.id), !catalogRow.models.isEmpty {
            let mine = ProviderPrefs.providerKey(model.catalog.mainProvider) == row.id
            Section {
                ChooserRow(title: "Default Model", value: mine ? name(model.catalog.mainModel, row) : "Another Provider", alone: true) {
                    let view = ModelChooserView(catalog: model.catalog, title: "Default Model", currentProvider: catalogRow.slug,
                                                currentModel: mine ? model.catalog.mainModel : "",
                                                note: SettingsWords.mainModelFooter(defaultBot: router.defaultBotName, otherBots: router.hasOtherBots)) { provider, picked in
                        router.closeChooser()
                        setMainModel(provider: provider, model: picked, confirm: false)
                    }
                    router.openChooser("Default Model", view)
                }
                .disabled(locked)
                .accessibilityIdentifier("provider-page.default-model")
            } footer: { HQSectionFooter {
                Text(SettingsWords.mainModelFooter(defaultBot: router.defaultBotName, otherBots: router.hasOtherBots))
            } }
        }
    }

    private func saveEndpointModel(_ endpoint: CustomProvider, _ picked: String) {
        var draft = CustomProviderDraft(endpoint)
        draft.choose(picked)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.custom.save(draft)
                Haptics.play(.success)
            } catch {
                failure = (error as? CustomProviderFailure)?.text ?? SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    private func setMainModel(provider: String, model picked: String, confirm: Bool) {
        guard !model.readOnly, let api = model.api else { failure = BotWriteError.readOnlyReason; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await api.setModel(scope: "main", provider: provider, model: picked,
                                           baseURL: model.catalog.provider(provider)?.apiURL, confirm: confirm)
                Haptics.play(.success)
                AppLog.note("settings", "main model changed (provider page)")
                router.services.refreshBots()
                await model.catalog.load()
            } catch ModelSetError.confirm(let message) {
                TextPrompt.confirmPlain(title: "Use \(ModelNames.displayModelName(picked, provider: provider))?", message: message,
                                        action: "Use It", from: router.presenter) {
                    setMainModel(provider: provider, model: picked, confirm: true)
                }
            } catch {
                AppLog.note("settings", "main model change failed: \(type(of: error))")
                failure = SettingsErrorText.save(error)
                Haptics.play(.error)
            }
        }
    }

    // MARK: Key, connection, account

    @ViewBuilder private func keySection(_ row: ManagedProvider) -> some View {
        if let endpoint = row.endpoint {
            Section {
                ValueRow(title: "Address, Key and Connection", value: endpoint.hasKey ? "Key saved" : "No key") {
                    CustomProviderPages.open(endpoint, model: model.custom, router: router)
                }
                .accessibilityIdentifier("provider-page.connection")
                Button(testing ? "Testing…" : "Test Connection") { runTest(endpoint, row) }
                    .disabled(testing)
                    .hqMacPushButton(leading: true)
                    .accessibilityIdentifier("provider-page.test")
                if let test {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(test.ok ? Color.green : Color.hqRed)
                        Text(test.summary).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    }
                    .hqRowPadding(4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-page.test-result")
                }
            } header: { HQSectionLabel {
                Text("Connection")
            } } footer: { HQSectionFooter {
                Text("Test Connection asks the service which models it has; they join the list above.")
            } }
        }
        if !row.keys.isEmpty {
            Section {
                ForEach(row.keys, id: \.key) { info in
                    EnvKeyRow(info: info, model: model.env, router: router)
                }
            } header: { HQSectionLabel {
                Text(row.keys.count == 1 ? "Key" : "Keys")
            } } footer: { HQSectionFooter {
                Text("Saved on \(HostWord.phrase), never in Hermes HQ.")
            } }
        }
        if let account = row.account {
            Section {
                LabeledContent("Account", value: account.connected ? (account.detail ?? "Signed In") : "Not Signed In")
                    .hqRowPadding(4)
                    .accessibilityIdentifier("provider-page.account")
            } footer: { HQSectionFooter {
                Text("You sign in to \(row.originalName) on \(HostWord.phrase).")
            } }
        }
    }

    private func runTest(_ endpoint: CustomProvider, _ row: ManagedProvider) {
        guard !testing else { return }
        testing = true
        test = nil
        Task {
            defer { testing = false }
            do {
                let answer = try await model.custom.test(CustomProviderDraft(endpoint))
                test = answer
                if answer.ok { found = answer.models }
                Haptics.play(answer.ok ? .success : .error)
            } catch {
                AppLog.note("settings", "provider page test failed: \(type(of: error))")
                test = CustomProviderTest(ok: false, reachable: false, message: SettingsErrorText.save(error))
                Haptics.play(.error)
            }
        }
    }

    // MARK: Remove

    @ViewBuilder private func removeSection(_ row: ManagedProvider) -> some View {
        if !model.readOnly {
            Section {
                if case .cannot = row.removal {
                    Button("Remove Provider", role: .destructive) {}
                        .disabled(true)
                        .hqMacFormButton(destructive: true)
                        .accessibilityIdentifier("provider-page.remove")
                } else {
                    Button(model.removing == row.id ? "Removing…" : row.removal == .signOut ? "Sign Out" : "Remove Provider", role: .destructive) {
                        model.askRemove(row, router: router) { router.navigation?.popViewController(animated: true) }
                    }
                    .disabled(model.removing != nil)
                    .hqMacFormButton(destructive: true)
                    .accessibilityIdentifier("provider-page.remove")
                }
            } footer: { HQSectionFooter {
                Text(removeFooter(row)).accessibilityIdentifier("provider-page.remove-footer")
            } }
        }
    }

    private func removeFooter(_ row: ManagedProvider) -> String {
        switch row.removal {
        case .cannot(let reason): return reason
        case .deleteEndpoint: return "Removes it and its saved key from \(HostWord.phrase)."
        case .removeKeys: return "Removes its key from \(HostWord.phrase). You can add it again under +."
        case .removeKeysAndSignOut: return "Removes its key and signs out of it on \(HostWord.phrase)."
        case .signOut: return "Signs out of it on \(HostWord.phrase)."
        }
    }
}
