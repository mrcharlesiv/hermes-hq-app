// Capabilities › Tools (docs/spec/3x-capabilities.md §4): the bot's toolsets with a switch each, an "All Tools" switch,
// use counts, and a page per tool.

import SwiftUI
import UIKit

struct ToolsetsSections: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter

    var body: some View {
        if let toolsets = model.toolsets {
            let shown = model.shownToolsets
            if toolsets.isEmpty {
                // Stress test 2026-10-28 #90 (both): the app's empty state (as Skills draws it), not a bare card.
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("No Tools", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text("This gateway has no tools to turn on or off.").hqMacFont(MacType.emptyBodyFont)
                    }
                    .listRowBackground(Color.clear)
                    // [mac] Stress test 2026-10-28 round 7: no card in either look (the Desktop Look boxed it), centred
                    // under the Bot and tab rows as Speech to Text's empty state is.
                    .hqMacEmptyPlacement()
                    .hqMacListedEmptyState(above: 160)
                    .accessibilityIdentifier("tools.empty")
                }
            } else if shown.isEmpty {
                Section { Text("No Results for “\(model.query)”").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
            } else {
                Section {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.readOnly {
                        Toggle(isOn: Binding(get: { model.allToolsOn }, set: { model.setAllTools($0) })) {
                            Text("All Tools").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        }
                        .disabled(!model.toolToggling.isEmpty)
                        .accessibilityHint("Turn every tool on or off")
                        .accessibilityIdentifier("toolset-switch-all")
                        .padding(.vertical, 3)
                    }
                    ForEach(shown) { toolset in
                        ToolsetRow(toolset: toolset, meta: model.toolMeta(toolset), busy: model.toolToggling.contains(toolset.name),
                                   readOnly: model.readOnly,
                                   toggle: { model.setToolset(toolset, enabled: $0) },
                                   open: { router.push(ToolsetPageController(model: model, toolset: toolset, router: router)) })
                    }
                } footer: { HQSectionFooter {
                    Text("Changes apply to new chats.")
                } }
            }
        } else if model.toolsTooOld {
            Section {
                Text("This gateway’s Hermes is too old to list tools here. Update Hermes on \(HostWord.updateTarget).")
                    .foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                HermesUpdateButton()
            }
        } else if let error = model.toolsError {
            LoadErrorSection(title: "Couldn’t Load Tools", reason: error) { Task { await model.reloadTools() } }
        } else if !model.isConnected {
            Section { Text("Waiting for your gateway…").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
        } else {
            Section { ForEach(0..<3, id: \.self) { _ in SkeletonLine() } }
        }
    }
}

struct ToolsetRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let toolset: Toolset
    let meta: String
    let busy: Bool
    let readOnly: Bool
    let toggle: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toolset.label).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                        if !toolset.description.isEmpty {
                            Text(toolset.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                        }
                        Text("\(Text(meta).foregroundStyle(Color.hqLabel2))\(Text(toolset.configured ? "" : " · ").foregroundStyle(Color.hqLabel2))\(Text(toolset.configured ? "" : "Needs keys").foregroundStyle(Color.hqOrange))")
                            .font(Font.hq(.caption))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolset-row-\(toolset.name)")
            if !readOnly {
                Toggle("", isOn: Binding(get: { toolset.enabled }, set: { toggle($0) }))
                    .labelsHidden()
                    .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                    .disabled(busy)
                    .accessibilityLabel(toolset.label)
                    .accessibilityIdentifier("toolset-switch-\(toolset.name)")
            }
        }
        .padding(.vertical, Theme.isDesktop ? 3 : 0) // [compact] iOS look: the list row's own inset only
    }
}

// MARK: - Tool page

@MainActor @Observable
final class ToolsetPageModel {
    let parent: CapabilitiesModel
    let name: String
    let profile: String
    let bot: String
    @ObservationIgnored weak var presenter: UIViewController?

    enum Setup { case loading, absent, failed, loaded(ToolsetConfig) }
    var setup: Setup = .loading
    var expanded: String?
    var selecting: String?
    var needsNous: String?
    var notice: String?
    var showAll = false
    var models: ToolModels?
    var settingModel: String?
    var backends: [TerminalBackend]?
    var backendsFailed = false
    var settingBackend: String?
    /// One-time install: nil idle, else its state.
    enum Install: Equatable { case running(String), done, failed }
    var install: Install?
    var keyBusy: String?
    /// Vision: this gateway lists a vision helper job, so "Choose Vision Model" has somewhere to go.
    var hasVisionTask = false

    init(parent: CapabilitiesModel, toolset: Toolset) {
        self.parent = parent
        name = toolset.name
        profile = parent.profile
        bot = parent.botName
    }

    var store: CapabilitiesStore? { parent.store }
    var readOnly: Bool { parent.readOnly }
    /// The live row (the list flips it), or nil once the bot changed underneath the page.
    var toolset: Toolset? { parent.profile == profile ? parent.toolsets?.first { $0.name == name } : nil }
    var config: ToolsetConfig? { if case .loaded(let config) = setup { return config } else { return nil } }
    var expandedProvider: ToolProvider? {
        guard let config else { return nil }
        return config.providers.first { $0.name == expanded } ?? config.providers.first(where: \.isActive) ?? config.providers.first
    }

    func load() async {
        guard let store else { return }
        do {
            if let config = try await store.toolsetConfig(name, profile: profile) {
                setup = .loaded(config)
                if expanded == nil { expanded = (config.providers.first(where: \.isActive) ?? config.providers.first)?.name }
                await loadModels()
            } else {
                setup = .absent
            }
        } catch {
            if config == nil { setup = .failed; AppLog.note("capabilities", "toolset \(name) config load failed: \(CapabilitiesStore.detail(error))") }
        }
        if name == "terminal" { await loadBackends() }
    }

    func loadModels() async {
        guard let store, let provider = expandedProvider else { models = nil; return }
        models = try? await store.toolModels(name, provider: provider.name, profile: profile)
    }

    func loadBackends() async {
        guard let store else { return }
        do { backends = try await store.terminalBackends(profile); backendsFailed = false }
        catch { if backends == nil { backendsFailed = !CapabilitiesStore.isNotFound(error) } }
    }

    func expand(_ provider: ToolProvider) {
        expanded = provider.name
        models = nil
        Task { await loadModels() }
    }

    func select(_ provider: ToolProvider, capability: String? = nil) {
        guard let store, selecting == nil, !readOnly else { return }
        Haptics.play(.selection)
        selecting = provider.name
        expanded = provider.name
        let start = ContinuousClock.now
        Task {
            defer { selecting = nil }
            do {
                let nous = try await store.selectProvider(name, provider: provider.name, capability: capability, profile: profile)
                needsNous = nous ? provider.name : nil
                await load()
                await parent.reloadTools()
                AppLog.trace("capabilities", "toolset \(name) select \(provider.name) ok in \(AppLog.ms(since: start)) ms, needsNous=\(nous)")
            } catch {
                AppLog.note("capabilities", "toolset \(name) select \(provider.name) failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                FailureAlert.present(title: "Couldn’t Select \(provider.name)", reason: CapabilitiesStore.detail(error), detail: "\(error)", from: presenter)
            }
        }
    }

    func saveKey(_ key: String, value: String) async -> Bool {
        guard let store else { return false }
        keyBusy = key
        defer { keyBusy = nil }
        let start = ContinuousClock.now
        do {
            try await store.setEnv(key, value: value, profile: profile)
            await load()
            await parent.reloadTools()
            AppLog.trace("capabilities", "tool key \(key) saved in \(AppLog.ms(since: start)) ms")
            return true
        } catch {
            AppLog.note("capabilities", "tool key \(key) save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            FailureAlert.present(title: "Couldn’t Save the Key", reason: CapabilitiesStore.detail(error), from: presenter)
            return false
        }
    }

    func removeKey(_ key: String) {
        guard let store else { return }
        TextPrompt.confirm(title: "Remove \(key)?", message: "\(bot) loses this key.", action: "Remove", from: presenter) { [self] in
            keyBusy = key
            let start = ContinuousClock.now
            Task {
                defer { keyBusy = nil }
                do {
                    try await store.deleteEnv(key, profile: profile)
                    Haptics.play(.success)   // as Settings › Keys' Remove
                    await load()
                    await parent.reloadTools()
                    AppLog.trace("capabilities", "tool key \(key) removed in \(AppLog.ms(since: start)) ms")
                } catch {
                    AppLog.note("capabilities", "tool key \(key) remove failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                    FailureAlert.present(title: "Couldn’t Remove \(key)", reason: CapabilitiesStore.detail(error), from: presenter)
                }
            }
        }
    }

    func runSetup(_ key: String) {
        guard let store, install == nil || install == .done || install == .failed, !readOnly else { return }
        install = .running("")
        let start = ContinuousClock.now
        AppLog.trace("capabilities", "toolset \(name) setup \(key) started")
        Task {
            var last: ActionStatus?
            do {
                for try await status in store.postSetup(name, key: key, profile: profile) {
                    last = status
                    let line = status.lines.last.map { McpEntryMask.phone.text(String($0.prefix(300))) } ?? ""
                    install = .running(line)
                }
            } catch {
                install = .failed
                Haptics.play(.error)
                AppLog.note("capabilities", "toolset \(name) setup \(key) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                return
            }
            if last?.exitCode == 0 {
                install = .done
                Haptics.play(.success)
                await load()
                await parent.reloadTools()
                AppLog.trace("capabilities", "toolset \(name) setup \(key) ok in \(AppLog.ms(since: start)) ms")
            } else {
                install = .failed
                Haptics.play(.error)
                AppLog.note("capabilities", "toolset \(name) setup \(key) ended with exit code \(last?.exitCode.map(String.init) ?? "none") after \(AppLog.ms(since: start)) ms")
            }
        }
    }

    func setModel(_ model: ToolModel) {
        guard let store, let models, settingModel == nil, !readOnly else { return }
        Haptics.play(.selection)
        settingModel = model.id
        let start = ContinuousClock.now
        Task {
            defer { settingModel = nil }
            do {
                try await store.setToolModel(name, model: model.id, provider: models.provider, profile: profile)
                self.models?.current = model.id
                flash("\(model.display) applies to new chats.")
                AppLog.trace("capabilities", "toolset \(name) model set in \(AppLog.ms(since: start)) ms")
            } catch {
                AppLog.note("capabilities", "toolset \(name) model set failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                FailureAlert.present(title: "Couldn’t Select \(model.display)", reason: CapabilitiesStore.detail(error), from: presenter)
            }
        }
    }

    func pick(_ backend: TerminalBackend) {
        guard !backend.active, !readOnly else { return }
        if backend.isReady { setBackend(backend); return }
        let rest = "Chats that start after this change will have no terminal or file tools until setup is finished."
        TextPrompt.confirm(title: "Select \(backend.label) Anyway?",
                           message: backend.detail.isEmpty ? "This backend isn’t set up yet. \(rest)" : "\(backend.detail) \(rest)",
                           action: "Select Anyway", from: presenter) { [self] in setBackend(backend) }
    }

    func setBackend(_ backend: TerminalBackend) {
        guard let store, settingBackend == nil else { return }
        Haptics.play(.selection)   // a pick among the rows, as `select` and `setModel`
        settingBackend = backend.name
        let start = ContinuousClock.now
        Task {
            defer { settingBackend = nil }
            do {
                try await store.setTerminalBackend(backend.name, profile: profile)
                await loadBackends()
                flash(backend.name == "local" ? "Terminal commands now run locally. Applies to new chats."
                      : "Terminal commands now run via \(backend.label). Applies to new chats.")
                AppLog.trace("capabilities", "terminal backend set to \(backend.name) in \(AppLog.ms(since: start)) ms")
            } catch {
                AppLog.note("capabilities", "terminal backend set to \(backend.name) failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                FailureAlert.present(title: "Couldn’t Select \(backend.label)", reason: CapabilitiesStore.detail(error), from: presenter)
            }
        }
    }

    func flash(_ text: String) {
        notice = text
        HQAnnounce.say(text)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }
}

final class ToolsetPageController: UIHostingController<HQScaledRoot<ToolsetPageView>> {
    let page: ToolsetPageModel

    init(model: CapabilitiesModel, toolset: Toolset, router: SettingsRouter) {
        page = ToolsetPageModel(parent: model, toolset: toolset)
        super.init(rootView: HQScaledRoot(ToolsetPageView(page: page, router: router)))
        title = toolset.label
        navigationItem.largeTitleDisplayMode = .never
        page.presenter = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await page.load() }
    }
}

struct ToolsetPageView: View {
    @Bindable var page: ToolsetPageModel
    let router: SettingsRouter
    @State private var editing: ToolEnvVar?

    var body: some View {
        List {
            if let toolset = page.toolset {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(toolset.description.isEmpty ? "No description." : toolset.description)
                            .foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                        if !toolset.configured {
                            Text("Needs keys").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqOrange)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.hqOrange.opacity(0.15), in: Capsule())
                                .accessibilityIdentifier("toolset-needs-keys")
                        }
                    }
                    .padding(.vertical, 3)
                    if !page.readOnly {
                        Toggle("On for \(page.bot)", isOn: Binding(get: { toolset.enabled }, set: { page.parent.setToolset(toolset, enabled: $0) }))
                            .disabled(page.parent.toolToggling.contains(toolset.name))
                            .accessibilityIdentifier("toolset-page-switch")
                    }
                }
                if let notice = page.notice {
                    Section { NoticeRow(text: notice, symbol: "checkmark.circle.fill").accessibilityIdentifier("toolset-notice") }
                }
                tools(toolset)
                ToolsetSetupSections(page: page, toolset: toolset, router: router, editing: $editing)
                Section {} footer: { HQSectionFooter {
                    Text(page.readOnly ? "This gateway is read-only." : "Changes apply to new chats.")
                } }
            } else {
                Section { Text("This tool isn’t on \(page.bot) any more.").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("toolset-page")
        .sheet(item: $editing) { variable in
            SecretEntrySheet(title: variable.prompt, name: variable.key, isSet: variable.isSet, placeholder: variable.placeholder,
                             save: { await page.saveKey(variable.key, value: $0) },
                             remove: variable.isSet ? { page.removeKey(variable.key) } : nil)
        }
    }

    @ViewBuilder private func tools(_ toolset: Toolset) -> some View {
        let sorted = toolset.tools.sorted { a, b in
            let ca = page.parent.toolUsage?[a] ?? 0, cb = page.parent.toolUsage?[b] ?? 0
            return ca != cb ? ca > cb : a < b
        }
        if !sorted.isEmpty {
            Section {
                ForEach(page.showAll ? sorted : Array(sorted.prefix(30)), id: \.self) { tool in
                    HStack {
                        Text(tool).font(Font.hq(.caption).monospaced()).foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 12)
                        if let count = page.parent.toolUsage?[tool], count > 0 {
                            Text("×\(Toolset.compact(count))").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                        }
                    }
                }
                if sorted.count > 30, !page.showAll {
                    Button("Show All \(sorted.count)") { page.showAll = true }
                }
            } header: { HQSectionLabel { Text(CapabilitiesModel.plural(sorted.count, "Tool", "Tools")) } }
        }
    }
}

/// A key editor: a secure field with Paste, Save, and Remove when one is stored. The value is never prefilled, logged
/// or kept after the sheet closes (owner rule: the owner pastes keys; nothing types them).
struct SecretEntrySheet: View {
    let title: String
    let name: String
    let isSet: Bool
    var placeholder: String?
    let save: (String) async -> Bool
    var remove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        SecureField(placeholder ?? (isSet ? "Enter a new value" : "Paste the key"), text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("secret.field")
                        Button("Paste") { if let text = UIPasteboard.general.string { value = text.trimmingCharacters(in: .whitespacesAndNewlines) } }
                            .hqBorderedButtonStyle()
                            .accessibilityIdentifier("secret.paste")
                    }
                } header: { HQSectionLabel {
                    Text(name)
                } } footer: { HQSectionFooter {
                    Text(isSet ? "A value is stored on \(HostWord.phrase). Saving replaces it." : "Stored on \(HostWord.phrase) for this bot.")
                        .foregroundStyle(Color(uiColor: HQPalette.glassInk2))   // [glass-audit] strong ink on the glass
                } }
                .hqSheetRows()
                if isSet, let remove {
                    Section {
                        Button("Remove", role: .destructive) { dismiss(); remove() }.accessibilityIdentifier("secret.remove")
                    }
                    .hqSheetRows()
                }
            }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // [ui-sizing 2026-11-09] Between Cancel and Save a key's name ("Brave Search API Key") was cut to
                // "Brave Search API…" on a 375 pt phone: the title shrinks to fit before it is cut.
                ToolbarItem(placement: .principal) {
                    Text(title).font(Font.hq(.headline)).lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            let ok = await save(value)
                            saving = false
                            if ok { value = ""; dismiss() }
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)   // ⌘Return saves, as in New Job
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .accessibilityIdentifier("secret.save")
                }
            }
        }
        .hqGlassSheetPage()   // [glass-audit] half height on Liquid Glass, as every other key and prompt sheet
        .presentationDetents([.medium, .large])
    }
}
