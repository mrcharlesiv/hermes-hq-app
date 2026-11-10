// Capabilities › Plugins (docs/spec/3x-capabilities.md §9): the bot's plugins with a switch each, Kanban's "Show in
// Hermes HQ", a page per plugin (update, uninstall, settings), Install from Git, and [find-plugins] Find Plugins
// (the Hermes catalog, PluginCatalogPages.swift).

import SwiftUI
import UIKit

struct PluginsSections: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter

    var body: some View {
        if let plugins = model.plugins {
            let shown = model.shownPlugins
            if plugins.isEmpty, model.pluginNotice == nil {
                // [find-plugins] No plugins yet: say so in the list, with Find Plugins under it to pick one (as Connectors
                // does), rather than the centred empty state with only Install from Git (stress test 2026-10-28 #90).
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Text(model.readOnly ? "\(model.botName) has no plugins." : "\(model.botName) has no plugins yet. Pick one below to add it.")
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("plugins.empty")
                        if !model.readOnly {
                            Button {
                                router.push(PluginInstallController(model: model, router: router))
                            } label: {
                                Label("Install from Git…", systemImage: "plus")
                            }
                            .accessibilityIdentifier("plugins.install")
                        }
                    } header: { HQSectionLabel {
                        Text("Plugins for \(model.botName)")
                    } } footer: { HQSectionFooter {
                        Text("Plugins add tools, memory, models and more. Changes take effect after your gateway restarts.")
                    } }
                }
                PluginFindSection(model: model, router: router)
            } else if shown.isEmpty, model.pluginNotice == nil, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // [find-plugins] A search none of the bot's plugins answers: only the catalog's matches, as Connectors.
                PluginFindSection(model: model, router: router)
            } else {
                Section {
                    if let notice = model.pluginNotice {
                        NoticeRow(text: notice, symbol: "info.circle.fill", tint: Color.hqTint,
                                  action: noticeActionTitle, run: noticeAction, close: { model.pluginNotice = nil; model.pluginNoticeAction = nil })
                            .accessibilityIdentifier("plugins.notice")
                    }
                    if plugins.isEmpty {
                        Text("No plugins for \(model.botName).").foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                    } else if shown.isEmpty {
                        Text("No Results for “\(model.query)”").foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                    }
                    ForEach(shown) { plugin in
                        PluginRow(plugin: plugin, busy: model.pluginBusy.contains(plugin.name), readOnly: model.readOnly,
                                  warnings: model.pluginWarnings[plugin.name] ?? [],
                                  toggle: { model.setPlugin(plugin, enabled: $0) },
                                  open: { router.push(PluginPageController(model: model, plugin: plugin, router: router)) },
                                  page: model.dashboardPage(for: plugin),
                                  openPage: { PluginPagesSection.open($0, model: model, router: router) })
                        if plugin.isKanban { kanban }
                    }
                    if !model.readOnly {
                        Button {
                            router.push(PluginInstallController(model: model, router: router))
                        } label: {
                            Label("Install from Git…", systemImage: "plus")
                        }
                        .accessibilityIdentifier("plugins.install")
                    }
                } header: { HQSectionLabel {
                    Text("Plugins for \(model.botName)")
                } } footer: { HQSectionFooter {
                    Text(plugins.isEmpty && !model.readOnly ? "Find one below, or install one from Git." : "Plugin changes take effect after your gateway restarts.")
                } }
                PluginFindSection(model: model, router: router)
            }
        } else if model.pluginsUnavailable {
            Section {
                Text("This gateway’s Hermes is too old to manage plugins here. Update Hermes on \(HostWord.updateTarget).")
                    .foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                    .accessibilityIdentifier("plugins.too-old")
                HermesUpdateButton()
            }
        } else if let error = model.pluginsError {
            LoadErrorSection(title: "Couldn’t Load Plugins", reason: error) { Task { await model.reloadPlugins() } }
        } else if !model.isConnected {
            Section { Text("Waiting for your gateway…").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
        } else {
            Section { ForEach(0..<3, id: \.self) { _ in SkeletonLine() } }
        }
    }

    private var noticeActionTitle: String? {
        switch model.pluginNoticeAction {
        case .openKeys: "Open Keys"
        case .setUp: "Set It Up"
        case nil: model.pluginNeedsKeys ? "Open Keys" : nil
        }
    }

    private var noticeAction: (() -> Void)? {
        switch model.pluginNoticeAction {
        case .setUp(let name):
            return {
                if let plugin = model.plugins?.first(where: { $0.name == name }), !plugin.schema.isEmpty {
                    router.push(PluginPageController(model: model, plugin: plugin, router: router))
                } else {
                    SettingsNavigator.openRoot("keys", router: router)
                }
            }
        case .openKeys: return { SettingsNavigator.openRoot("keys", router: router) }
        case nil: return model.pluginNeedsKeys ? { SettingsNavigator.openRoot("keys", router: router) } : nil
        }
    }

    /// The same device setting as Settings › Appearance › Tabs › Kanban Tab; works on a read-only gateway and for every bot.
    private var kanban: some View {
        let _ = model.kanbanTick
        let on = model.kanbanShown
        return Toggle(isOn: Binding(get: { on }, set: { model.setKanbanShown($0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Show in Hermes HQ").foregroundStyle(Color.hqLabel)
                Text(on ? "A task board your bots work from. It’s the Kanban tab." : "A task board your bots work from. Turn it on to add a Kanban tab.")
                    .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel("Show Kanban in Hermes HQ")
        .accessibilityIdentifier("plugin-kanban-show")
        .padding(.vertical, 3)
    }
}

struct PluginRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let plugin: PluginInfo
    let busy: Bool
    let readOnly: Bool
    let warnings: [String]
    let toggle: (Bool) -> Void
    let open: () -> Void
    /// [plugin-pages] The page the plugin adds, opened by the row's Open.
    var page: PluginDashboardPage? = nil
    var openPage: (PluginDashboardPage) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Text(plugin.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel))\(Text(plugin.version.isEmpty ? "" : "  \(plugin.version)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2))")
                        if !plugin.description.isEmpty {
                            Text(plugin.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                        }
                        ForEach(plugin.servers.compactMap(\.words), id: \.self) { words in
                            Text(words).font(Font.hq(.caption)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if plugin.updateAvailable { Text("Update available").font(Font.hq(.caption)).foregroundStyle(Color.hqTint) }
                        if plugin.key == nil {
                            Text("Update Hermes on \(HostWord.updateTarget) to turn this plugin on or off here.").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(warnings.prefix(3), id: \.self) { Text($0).font(Font.hq(.caption)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plugin-row-\(plugin.name)")
            .contextMenu {
                if let page {
                    Button { openPage(page) } label: { Label("Open \(page.label)", systemImage: page.symbol) }
                }
            }
            if let page {
                Button("Open") { openPage(page) }
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .hqRowActionButtonStyle()
                    .accessibilityLabel("Open \(page.label)")
                    .accessibilityIdentifier("plugin-open-\(plugin.name)")
            }
            if let key = plugin.key, !readOnly {
                Toggle("", isOn: Binding(get: { plugin.enabled }, set: { toggle($0) }))
                    .labelsHidden()
                    .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                    .disabled(busy)
                    .accessibilityLabel(plugin.name)
                    .accessibilityIdentifier("plugin-switch-\(key)")
            }
        }
        .padding(.vertical, Theme.isDesktop ? 3 : 0) // [compact] iOS look: the list row's own inset only
    }
}

// MARK: - Plugin page

@MainActor @Observable
final class PluginPageModel {
    let parent: CapabilitiesModel
    let name: String
    let profile: String
    let bot: String
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored var pop: (() -> Void)?
    /// [plugin-pages] For the page's Open (a plugin that adds a page).
    @ObservationIgnored var router: SettingsRouter?
    var busy = false
    var notice: String?
    // Settings form: drafts by field key. Secrets live here in memory only and die with the page.
    var texts: [String: String] = [:]
    var bools: [String: Bool] = [:]
    var secrets: [String: String] = [:]
    var fieldError: String?
    var saving = false

    init(parent: CapabilitiesModel, plugin: PluginInfo) {
        self.parent = parent
        name = plugin.name
        profile = parent.profile
        bot = parent.botName
        reset(plugin)
    }

    var plugin: PluginInfo? { parent.profile == profile ? parent.plugins?.first { $0.name == name } : nil }
    var store: CapabilitiesStore? { parent.store }
    var readOnly: Bool { parent.readOnly }
    var canEdit: Bool { !readOnly && plugin?.key != nil }

    static func text(_ field: PluginField) -> String {
        guard let value = field.value ?? field.fallback else { return field.type == "enum" ? (field.choices.first ?? "") : "" }
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default:
            guard let data = try? value.encoded(), let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
            return String(data: pretty, encoding: .utf8) ?? ""
        }
    }

    func reset(_ plugin: PluginInfo) {
        texts = [:]; bools = [:]
        for field in plugin.schema {
            if field.type == "boolean" { bools[field.key] = (field.value ?? field.fallback)?.bool ?? false }
            else if field.type != "secret" { texts[field.key] = Self.text(field) }
        }
    }

    /// The changed non-secret values, or the first field error.
    func changes(_ plugin: PluginInfo) -> Result<[String: JSONValue], BotWriteError> {
        var out: [String: JSONValue] = [:]
        for field in plugin.schema {
            switch field.type {
            case "boolean":
                let now = bools[field.key] ?? false
                if now != ((field.value ?? field.fallback)?.bool ?? false) { out[field.key] = .bool(now) }
            case "string", "enum":
                let now = texts[field.key] ?? ""
                if now != Self.text(field) { out[field.key] = .string(now) }
            case "number":
                let now = (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                guard now != Self.text(field) else { continue }
                guard let number = Double(now), number.isFinite else { return .failure(BotWriteError(title: "", reason: "\(field.label): expected a number")) }
                out[field.key] = .number(number)
            case "json":
                let now = texts[field.key] ?? ""
                guard now != Self.text(field) else { continue }
                guard let data = now.data(using: .utf8), let value = try? JSONValue.parse(data) else {
                    return .failure(BotWriteError(title: "", reason: "\(field.label): not valid JSON"))
                }
                out[field.key] = value
            default: continue
            }
        }
        return .success(out)
    }

    func typedSecrets(_ plugin: PluginInfo) -> [(env: String, value: String)] {
        plugin.schema.compactMap { field in
            guard field.type == "secret", let env = field.env, let value = secrets[field.key], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (env, value)
        }
    }

    var dirty: Bool {
        guard let plugin else { return false }
        if !typedSecrets(plugin).isEmpty { return true }
        if case .success(let changes) = changes(plugin) { return !changes.isEmpty }
        return true
    }

    func saveSettings() {
        guard let store, let plugin, let key = plugin.key, !saving else { return }
        fieldError = nil
        let values: [String: JSONValue]
        switch changes(plugin) {
        case .failure(let error): fieldError = error.reason; return
        case .success(let changes): values = changes
        }
        let typed = typedSecrets(plugin)
        saving = true
        let start = ContinuousClock.now
        Task {
            defer { saving = false }
            do {
                // Secrets first; if one fails nothing else is sent, and what was typed stays in its field.
                for secret in typed { try await store.setEnv(secret.env, value: secret.value, profile: profile) }
                if !values.isEmpty { _ = try await store.plugin(.settings(key: key, values: values), profile: profile) }
                secrets = [:]
                await parent.reloadPlugins()
                if let fresh = self.plugin { reset(fresh) }
                Haptics.play(.success)
                flash("\(name) settings saved.")
                AppLog.trace("capabilities", "plugin \(name) settings saved in \(AppLog.ms(since: start)) ms, \(values.count) field(s), \(typed.count) secret(s)")
            } catch {
                AppLog.note("capabilities", "plugin \(name) settings save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                FailureAlert.present(title: "Couldn’t Save \(name) Settings", reason: McpEntryMask.phone.text(CapabilitiesStore.detail(error)), from: presenter)
            }
        }
    }

    func flash(_ text: String) {
        notice = text
        HQAnnounce.say(text)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == text { notice = nil }
        }
    }

    func update(accept: Bool = false) {
        guard let store, let plugin, !busy else { return }
        busy = true
        let start = ContinuousClock.now
        Task {
            defer { busy = false }
            do {
                let result = try await store.plugin(.update(name: plugin.name, accept: accept), profile: profile)
                if result.consentRequired, !accept {
                    busy = false
                    AppLog.trace("capabilities", "plugin \(name) update asks consent for \(result.deltaLines.count) line(s)")
                    askConsent(result.deltaLines)
                    return
                }
                await parent.reloadPlugins()
                flash("\(name) updated. Restart your gateway to apply.")
                AppLog.trace("capabilities", "plugin \(name) update ok in \(AppLog.ms(since: start)) ms, accepted=\(accept)")
            } catch {
                AppLog.note("capabilities", "plugin \(name) update failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                FailureAlert.present(title: "Couldn’t Update \(name)", reason: McpEntryMask.phone.text(CapabilitiesStore.detail(error)), from: presenter)
            }
        }
    }

    private func askConsent(_ lines: [String]) {
        guard let host = FailureAlert.topmost(presenter) else { return }
        var shown = Array(lines.prefix(12))
        if lines.count > 12 { shown.append("and \(lines.count - 12) more") }
        let alert = UIAlertController(title: "\(name) asks for more",
                                      message: "The new version adds things the installed one does not have. Apply it only if you trust them:\n"
                                        + shown.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply Update", style: .default) { [weak self] _ in self?.update(accept: true) })
        host.present(alert, animated: true)
    }

    func uninstall() {
        guard let store, !busy else { return }
        TextPrompt.confirm(title: "Uninstall \(name)?", message: "This deletes the plugin’s files from \(bot) on \(HostWord.phrase). You can install it again later.",
                           action: "Uninstall", from: presenter) { [self] in
            busy = true
            let start = ContinuousClock.now
            Task {
                defer { busy = false }
                do {
                    _ = try await store.plugin(.remove(name: name), profile: profile)
                    parent.pluginNotice = "\(name) uninstalled. Restart your gateway to unload it."
                    parent.pluginNeedsKeys = false
                    parent.pluginNoticeAction = nil
                    await parent.reloadPlugins()
                    AppLog.trace("capabilities", "plugin \(name) uninstalled in \(AppLog.ms(since: start)) ms")
                    pop?()
                } catch {
                    AppLog.note("capabilities", "plugin \(name) uninstall failed after \(AppLog.ms(since: start)) ms: \(CapabilitiesStore.detail(error))")
                    FailureAlert.present(title: "Couldn’t Uninstall \(name)", reason: McpEntryMask.phone.text(CapabilitiesStore.detail(error)), from: presenter)
                }
            }
        }
    }
}

final class PluginPageController: UIHostingController<HQScaledRoot<PluginPageView>> {
    let page: PluginPageModel

    init(model: CapabilitiesModel, plugin: PluginInfo, router: SettingsRouter) {
        page = PluginPageModel(parent: model, plugin: plugin)
        super.init(rootView: HQScaledRoot(PluginPageView(page: page)))
        title = plugin.name
        navigationItem.largeTitleDisplayMode = .never
        page.presenter = self
        page.router = router
        page.pop = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        // Leaving with unsaved settings asks first (§9.5).
        navigationItem.backAction = UIAction { [weak self] _ in
            guard let self else { return }
            guard self.page.canEdit, self.page.dirty else { self.navigationController?.popViewController(animated: true); return }
            let alert = UIAlertController(title: "Discard Changes?", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in self.navigationController?.popViewController(animated: true) })
            alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct PluginPageView: View {
    @Bindable var page: PluginPageModel

    var body: some View {
        List {
            if let plugin = page.plugin {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        if !plugin.description.isEmpty {
                            Text(plugin.description).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        }
                        if !plugin.version.isEmpty { Text("Version \(plugin.version)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
                        if let source = plugin.sourceWords { Text(source).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
                    }
                    .padding(.vertical, 3)
                    if let key = plugin.key, !page.readOnly {
                        Toggle("On for \(page.bot)", isOn: Binding(get: { plugin.enabled }, set: { page.parent.setPlugin(plugin, enabled: $0) }))
                            .disabled(page.parent.pluginBusy.contains(plugin.name))
                            .accessibilityIdentifier("plugin-page-switch-\(key)")
                    }
                } footer: { HQSectionFooter {
                    if plugin.hasDesktopHalf, !plugin.isKanban { Text("Part of this plugin shows only in Hermes on a computer.") }
                } }
                if let shown = page.parent.dashboardPage(for: plugin), let router = page.router {
                    Section {
                        Button { PluginPagesSection.open(shown, model: page.parent, router: router) } label: {
                            Text("Open \(shown.label)").font(Font.hq(.body).weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .hqGlassProminentButtonStyle()
                        .accessibilityIdentifier("plugin.open-page")
                    } footer: { HQSectionFooter {
                        Text("\(plugin.name) adds a page. It opens here, as it does in the Hermes dashboard.")
                    } }
                    .listRowBackground(Color.clear)
                }
                if let notice = page.notice {
                    Section { NoticeRow(text: notice, symbol: "checkmark.circle.fill").accessibilityIdentifier("plugin.notice") }
                }
                if !page.readOnly, plugin.updateAvailable || plugin.canUninstall {
                    Section {
                        if plugin.updateAvailable {
                            Button(page.busy ? "Updating…" : "Update to \(plugin.catalogVersion ?? String((plugin.catalogSha ?? "the latest version").prefix(7)))") { page.update() }
                                .disabled(page.busy)
                                .accessibilityIdentifier("plugin.update")
                        }
                        if plugin.canUninstall {
                            Button("Uninstall", role: .destructive) { page.uninstall() }.disabled(page.busy)
                                .accessibilityIdentifier("plugin.uninstall")
                        }
                    }
                }
                if !plugin.schema.isEmpty { settings(plugin) }
            } else {
                Section { Text("This plugin isn’t on \(page.bot) any more.").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("plugin-page")
    }

    @ViewBuilder private func settings(_ plugin: PluginInfo) -> some View {
        let editable = page.canEdit
        Section {
            ForEach(plugin.schema) { field in
                fieldRow(field, editable: editable)
            }
            if let error = page.fieldError {
                Text(error).font(Font.hq(.subheadline)).foregroundStyle(.red).accessibilityIdentifier("plugin.settings.error")
            }
            if editable {
                Button(page.saving ? "Saving…" : "Save Settings") { page.saveSettings() }
                    .disabled(page.saving || !page.dirty)
                    .accessibilityIdentifier("plugin.settings.save")
            }
        } header: { HQSectionLabel {
            Text("Settings")
        } } footer: { HQSectionFooter {
            if plugin.key == nil { Text("Update Hermes on \(HostWord.updateTarget) to change these here.") }
        } }
    }

    @ViewBuilder private func fieldRow(_ field: PluginField, editable: Bool) -> some View {
        let id = "plugin.settings.\(field.key)"
        VStack(alignment: .leading, spacing: 6) {
            switch field.type {
            case "boolean":
                Toggle(isOn: Binding(get: { page.bools[field.key] ?? false }, set: { page.bools[field.key] = $0 })) { label(field) }
                    .disabled(!editable).accessibilityIdentifier(id)
            case "enum":
                HStack {
                    label(field)
                    Spacer()
                    Picker("", selection: Binding(get: { page.texts[field.key] ?? "" }, set: { page.texts[field.key] = $0 })) {
                        ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).disabled(!editable).accessibilityIdentifier(id)
                }
            case "secret":
                label(field)
                if field.env == nil {
                    Text("Set this one on \(HostWord.phrase).").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                } else {
                    SecureField(field.hasValue ? "•••••••• (set)" : "", text: Binding(get: { page.secrets[field.key] ?? "" }, set: { page.secrets[field.key] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(!editable).accessibilityIdentifier(id)
                        .accessibilityHint("Saved as \(field.env ?? "") on the computer running Hermes")
                }
            case "json":
                label(field)
                TextEditor(text: Binding(get: { page.texts[field.key] ?? "" }, set: { page.texts[field.key] = $0 }))
                    .font(Font.hq(.footnote).monospaced()).frame(minHeight: 80, maxHeight: 220)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!editable).accessibilityIdentifier(id)
            case "string", "number":
                label(field)
                TextField(field.label, text: Binding(get: { page.texts[field.key] ?? "" }, set: { page.texts[field.key] = $0 }))
                    .keyboardType(field.type == "number" ? .decimalPad : .default)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!editable).accessibilityIdentifier(id)
                    .modifier(NumberPadDoneIf(on: field.type == "number"))   // [diagnostics] the decimal pad has no Return
            default:
                label(field)
                Text(McpEntryMask.phone.text(PluginPageModel.text(field))).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
            let caption = [field.description,
                           field.type == "secret" && field.env != nil
                               ? "Saved as a secret on the computer running Hermes. Leave blank to keep the current value." : ""]   // the env name: the field's hint (UX study #180)
                .filter { !$0.isEmpty }.joined(separator: " ")
            if !caption.isEmpty { Text(caption).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 3)
    }

    private func label(_ field: PluginField) -> some View {
        Text("\(Text(field.label).foregroundStyle(Color.hqLabel))\(Text(field.required ? "" : " (optional)").foregroundStyle(Color.hqLabel2))")
    }
}

// MARK: - Install from Git (§9.4)

nonisolated enum PluginRepo {
    enum Check: Equatable { case empty, ok, insecure, invalid }

    static func check(_ raw: String) -> Check {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if value.count > 500 || value.hasPrefix("-") || value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) {
            return .invalid
        }
        let lower = value.lowercased()
        if lower.hasPrefix("https://") { return URL(string: value)?.host == nil ? .invalid : .ok }
        if JSRegex(#"^git@[A-Za-z0-9.-]+:[\w.~/-]+$"#).test(value) { return .ok }
        if JSRegex(#"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#).test(value) { return .ok }
        if JSRegex(#"^[a-z][a-z0-9+.-]*:"#, "i").test(value) { return .insecure }
        return .invalid
    }

    static func refValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || JSRegex(#"^[0-9a-fA-F]{40}$"#).test(value)
    }
}

@MainActor @Observable
final class PluginInstallState {
    let model: CapabilitiesModel
    var repo = ""
    var enable = true
    var force = false
    var ref = ""
    var installing = false
    var already: String?
    var uncertain = false
    var lockedUntil: Date?
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored var pop: (() -> Void)?
    /// One install at a time per gateway.
    static var running = false

    init(model: CapabilitiesModel) { self.model = model }

    var check: PluginRepo.Check { PluginRepo.check(repo) }
    var canInstall: Bool {
        (check == .ok || check == .insecure) && PluginRepo.refValid(ref) && !installing && !Self.running && (lockedUntil.map { $0 < Date() } ?? true)
    }

    func ask() {
        guard canInstall else { return }
        let identifier = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        TextPrompt.confirmPlain(title: "Install This Plugin?",
                                message: "Hermes will download \(identifier) and run its code on \(HostWord.phrase) for \(model.botName).",
                                action: "Install", from: presenter) { [weak self] in self?.run(identifier) }
    }

    private func run(_ identifier: String) {
        guard let store = model.store, !Self.running else { return }
        installing = true
        Self.running = true
        already = nil
        uncertain = false
        let profile = model.profile, model = self.model
        let pin = ref.trimmingCharacters(in: .whitespaces)
        let action = PluginAction.install(identifier: identifier, force: force, enable: enable, ref: pin.isEmpty ? nil : pin)
        let start = ContinuousClock.now
        let tag = AppLog.tag(identifier)
        AppLog.trace("capabilities", "plugin install \(tag) started, force=\(force), enable=\(enable), pinned=\(!pin.isEmpty)")
        Task {
            defer { installing = false; Self.running = false }
            do {
                let result = try await store.plugin(action, profile: profile)
                model.noteInstalled(result, name: result.name ?? identifier)
                Haptics.play(.success)
                await model.reloadPlugins()
                AppLog.trace("capabilities", "plugin install \(tag) ok in \(AppLog.ms(since: start)) ms, missingEnv=\(result.missingEnv.count), needsRestart=\(result.needsRestart), warnings=\(result.warnings.count)")
                pop?()
            } catch {
                let detail = CapabilitiesStore.detail(error)
                if (error as? RPCError)?.code == 4090 || detail.lowercased().contains("already installed") {
                    already = "\(identifier) is already installed. Turn on Replace If Already Installed to install it again."
                    AppLog.note("capabilities", "plugin install \(tag) refused after \(AppLog.ms(since: start)) ms: already installed")
                } else if detail.lowercased().contains("timed out") || detail.lowercased().contains("took too long") || error is CancellationError {
                    uncertain = true
                    lockedUntil = Date().addingTimeInterval(30)
                    AppLog.note("capabilities", "plugin install \(tag) ended with no status after \(AppLog.ms(since: start)) ms (timed out)")
                    Task { try? await Task.sleep(for: .seconds(30)); lockedUntil = nil }
                } else {
                    AppLog.note("capabilities", "plugin install \(tag) failed after \(AppLog.ms(since: start)) ms: \(detail)")
                    FailureAlert.present(title: "Couldn’t Install Plugin", reason: String(McpEntryMask.phone.text(detail).prefix(600)), from: presenter)
                }
            }
        }
    }
}

final class PluginInstallController: UIHostingController<HQScaledRoot<PluginInstallView>> {
    init(model: CapabilitiesModel, router: SettingsRouter) {
        let state = PluginInstallState(model: model)
        super.init(rootView: HQScaledRoot(PluginInstallView(state: state)))
        title = "Install Plugin"
        navigationItem.largeTitleDisplayMode = .never
        state.presenter = self
        state.pop = { [weak self] in
            guard let self, self.navigationController?.topViewController === self else { return }
            self.navigationController?.popViewController(animated: true)
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct PluginInstallView: View {
    @Bindable var state: PluginInstallState

    var body: some View {
        Form {
            Section {
                Text("Install only from sources you trust. A plugin is code that runs on \(HostWord.phrase).")
                    .foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                TextField("https://github.com/owner/repo", text: $state.repo)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("plugins.install.repo")
            } header: { HQSectionLabel {
                Text("Repository")
            } } footer: { HQSectionFooter {
                if state.check == .invalid {
                    Text("That doesn’t look like a repository address.").foregroundStyle(.red).accessibilityIdentifier("plugins.install.invalid")
                } else if state.check == .insecure {
                    Text("This URL uses an insecure or local scheme. Prefer https:// or git@ for production installs.").foregroundStyle(.orange)
                        .accessibilityIdentifier("plugins.install.insecure")
                } else if let already = state.already {
                    Text(already).foregroundStyle(.red).accessibilityIdentifier("plugins.install.already")
                }
            } }
            Section {
                Toggle("Turn On After Installing", isOn: $state.enable).accessibilityIdentifier("plugins.install.enable")
                Toggle("Replace If Already Installed", isOn: $state.force).accessibilityIdentifier("plugins.install.force")
                TextField("Full 40-character commit SHA", text: $state.ref)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(Font.hq(.body).monospaced())
                    .accessibilityLabel("Pin to Commit (Optional)")
                    .accessibilityIdentifier("plugins.install.ref")
            } header: { HQSectionLabel {
                Text("Options")
            } } footer: { HQSectionFooter {
                if PluginRepo.refValid(state.ref) {
                    Text("Pin to Commit (Optional): everyone installing this SHA gets the same code; the plugin then refuses updates until re-pinned. Leave empty for the latest commit.")
                } else {
                    Text("Must be a full 40-character commit SHA (branches and tags are not accepted).").foregroundStyle(.red)
                        .accessibilityIdentifier("plugins.install.ref-invalid")
                }
            } }
            if state.uncertain {
                Section {
                    NoticeRow(text: "Hermes stopped waiting for the install result, but the plugin may still be installing. Go back and \(DeviceWord.refresh) Plugins before trying Install again.",
                              symbol: "exclamationmark.triangle.fill", tint: .orange)
                        .accessibilityIdentifier("plugins.install.uncertain")
                }
            }
            Section {
                Button {
                    state.ask()
                } label: {
                    HStack(spacing: 8) {
                        if state.installing { ProgressView() }
                        Text(state.installing ? "Installing…" : "Install")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!state.canInstall)
                .accessibilityIdentifier("plugins.install.go")
            } footer: { HQSectionFooter {
                Text("Installs for \(state.model.botName). Plugin changes take effect after your gateway restarts.")
            } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .scrollDismissesKeyboard(.interactively)
    }
}
