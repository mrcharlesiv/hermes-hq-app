// Settings › Model, Chat Behavior, Workspace, Safety, Browser, Memory, Advanced: a section lists its pages
// (`config-subpages.ts`), and a page draws the gateway's own schema fields with one generic renderer
// (`config-field.tsx`): switches inline, everything else as a value row that opens its editor (a checkmark list, a
// number or text field, a list or JSON editor), with Reset to Default. Edits autosave through `GatewayConfigStore`.

import Observation
import SwiftUI
import UIKit

enum ConfigScreens {
    /// A section's page list (or its only page).
    @MainActor static func open(section: ConfigSection, router: SettingsRouter) {
        // [talk] Voice has rows of this iPhone's own, so it opens with or without the gateway's settings.
        if section.id == "voice" { VoiceSettingsScreens.openSection(router: router); return }
        guard let store = router.gatewaySettings?.configStore else { return }
        // [mac] Stress test 2026-10-28 #51: a flattened section holds its pages' fields, so it saves as a page does.
        router.push(section.title, ConfigSectionView(section: section, store: store, router: router),
                    onDisappear: flattensOnMac(section) ? { store.flush() } : nil)
    }

    /// [mac] Stress test 2026-10-28 #51: on the Mac a section of one to four plain pages (Chat Behavior, Workspace,
    /// Safety, Browser, Memory) draws its pages' fields on itself, one card per page, instead of a list of rows that
    /// each open a page (Chat Behavior › Attachments was three pages deep for one setting). Sections with pages of
    /// their own drawing (Model, Voice) or more pages (Advanced) keep their list.
    static func flattensOnMac(_ section: ConfigSection) -> Bool {
        DeviceWord.isMac && section.id != "voice" && section.pages.count <= 4
            && !section.pages.contains { ConfigCatalog.customPages.contains($0.key) }
    }

    @MainActor static func open(page: ConfigPage, router: SettingsRouter) {
        if let controller = makePage(page, router: router) { router.push(controller) }
    }

    @MainActor static func makePage(_ page: ConfigPage, router: SettingsRouter) -> UIViewController? {
        if let voice = VoiceSettingsScreens.makePage(page, router: router) { return voice }   // [talk]
        guard let store = router.gatewaySettings?.configStore else { return nil }
        func make<V: View>(_ view: V, flush: Bool = true) -> UIViewController {
            let controller = SettingsPageController(title: page.title, view)
            if flush { controller.onDisappear = { store.flush() } }
            return controller
        }
        switch page.key {
        case "model.main": return make(MainModelView(store: store, router: router))
        case "model.context": return make(ContextWindowView(store: store, router: router))   // [context-window]
        case "model.fallbacks": return make(FallbackModelsView(store: store, router: router))
        case "model.auxiliary": return make(AuxiliaryModelsView(router: router), flush: false)
        case "model.moa": return make(MixtureOfAgentsView(router: router), flush: false)
        default: return make(ConfigPageView(page: page, store: store, router: router))
        }
    }

    @MainActor static func openField(_ key: String, store: GatewayConfigStore, router: SettingsRouter) {
        if let controller = makeField(key, store: store, router: router) { router.push(controller) }
    }

    @MainActor static func makeField(_ key: String, store: GatewayConfigStore, router: SettingsRouter) -> UIViewController? {
        let field = store.field(key)
        let label = field?.label ?? ConfigCopy.labels[key] ?? ConfigText.pretty(String(key.split(separator: ".").last ?? Substring(key)))
        let controller: SettingsPageController<AnyView> = field?.control == .fallbackModels || key == "fallback_providers"
            ? SettingsPageController(title: "Fallback Models", AnyView(FallbackModelsView(store: store, router: router)))
            : SettingsPageController(title: label, AnyView(ConfigFieldEditor(key: key, store: store)))
        controller.onDisappear = { store.flush() }
        return controller
    }
}

// MARK: - A section's pages

struct ConfigSectionView: View {
    let section: ConfigSection
    let store: GatewayConfigStore
    let router: SettingsRouter

    var body: some View {
        if ConfigScreens.flattensOnMac(section) {
            flattened
        } else {
            pageList
        }
    }

    /// [mac] Stress test 2026-10-28 #51: the section's pages as cards of fields on this one form, each headed by its
    /// page's name; the section's footer under the last.
    private var flattened: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if store.config == nil {
                if case .failed(let text) = store.phase {
                    LoadFailureSection(title: "Couldn’t Load Settings", text: text) { Task { await store.load(force: true) } }
                } else {
                    LoadingSection(text: "Loading settings…")
                }
            } else {
                let pages = section.pages.filter { !store.fields($0).isEmpty || $0.key == MacAttachmentLimitRow.page }
                ForEach(pages) { page in
                    Section {
                        ForEach(store.fields(page)) { field in
                            MacConfigFieldRow(field: field, store: store, router: router)
                        }
                        if page.key == MacAttachmentLimitRow.page { MacAttachmentLimitRow() }
                    } header: { HQSectionLabel {
                        Text(page.title).accessibilityIdentifier("config-page.\(page.key)")
                    } } footer: { HQSectionFooter {
                        if page.id == pages.last?.id {
                            Text(Self.footer(section.id, defaultBot: router.services.bots.first { $0.id == "default" }?.name,
                                             otherBots: ((router.services as? SettingsServices)?.rosterCount ?? 0) > 1))
                                .accessibilityIdentifier("config-section.\(section.id).footer")
                        }
                    } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .task { await store.load() }
        .refreshable { await store.load(force: true) }
        .accessibilityIdentifier("config-section.\(section.id)")
    }

    private var pageList: some View {
        List { Group {
            Section {
                ForEach(section.pages) { page in
                    // [context-window] Its size where it's listed, so the row reads at a glance ("Automatic", "200K").
                    ValueRow(title: page.title, value: page.key == "model.context" && store.config != nil ? ContextWindow.summary(store.value(ContextWindow.key)) : nil,
                             systemImage: page.symbol) { ConfigScreens.open(page: page, router: router) }
                        .accessibilityIdentifier("config-page.\(page.key)")
                }
            } footer: { HQSectionFooter {
                Text(Self.footer(section.id, defaultBot: router.services.bots.first { $0.id == "default" }?.name,
                                 otherBots: ((router.services as? SettingsServices)?.rosterCount ?? 0) > 1))
                    .accessibilityIdentifier("config-section.\(section.id).footer")
            } }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .task { await store.load() }
        .accessibilityIdentifier("config-section.\(section.id)")
    }

    // UX study #24: where these are kept, as HostWord says it (never "your gateway"). Model names whose they are
    // (tester batch 3: "The models your bots use" read as every bot's).
    static func footer(_ id: String, defaultBot: String? = nil, otherBots: Bool = false) -> String {
        let saved = "Saved on \(HostWord.phrase)."
        return switch id {
        case "model": SettingsWords.modelSectionFooter(defaultBot: defaultBot, otherBots: otherBots)
        // [mac] Mac polish #132: the Mac's Attachments card also holds Largest Attachment, which is this Mac's own; the
        // footer under it said the whole card was saved on the computer running Hermes.
        case "chat": "How Hermes talks and what it does with attachments. "
            + (DeviceWord.isMac ? "Saved on \(HostWord.phrase), except Largest Attachment, which is set on this Mac." : saved)
        case "workspace": "Where Hermes works on \(HostWord.phrase). Saved there too."
        case "safety": "What Hermes asks before it acts, and what it keeps private. \(saved)"
        case "browser": "How Hermes’s own browser signs in and reaches local addresses. \(saved)"
        case "memory": "What Hermes remembers between chats, and how it keeps long chats in its context. \(saved)"
        default: "Limits and tools for power users. \(saved)"
        }
    }
}

// MARK: - A page of fields

struct ConfigPageView: View {
    let page: ConfigPage
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// Keys a custom page draws itself (they don't repeat here).
    var excluding: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List { Group {
                ConfigFieldsContent(page: page, store: store, router: router, excluding: excluding)
            }.hqMacSettingsRowInsets() }
            .settingsList().hqMacSettingsRows()
            .saveFailureFeedback(store.failure?.text)
            .task {
                await store.load()
                await ConfigFieldReveal.shared.reveal(store.fields(page).map(\.key), proxy: proxy)   // [mac] Mac polish #39
            }
            .refreshable { await store.load(force: true) }
            .accessibilityIdentifier("config-page.\(page.key).list")
        }
    }
}

/// [mac] A Settings search result for one setting opens its page scrolled to its row, marked for a moment as the
/// root's rows are, not a second page holding only that setting over the page that shows it (Mac polish #39).
@MainActor @Observable final class ConfigFieldReveal {
    static let shared = ConfigFieldReveal()
    /// The setting the page being opened scrolls to.
    @ObservationIgnored var pending: String?
    /// The row marked now (`rowID`).
    private(set) var marked: String?

    static func rowID(_ key: String) -> String { "config-field:\(key)" }

    /// The pending setting, when this page draws it: scrolled to once the push has landed, then marked for a moment.
    func reveal(_ keys: [String], proxy: ScrollViewProxy) async {
        guard let key = pending else { return }
        pending = nil
        guard keys.contains(key) else { return }
        try? await Task.sleep(for: .milliseconds(350))
        HQMotion.withAnimation { proxy.scrollTo(Self.rowID(key), anchor: .center) }
        marked = Self.rowID(key)
        try? await Task.sleep(for: .seconds(1.4))
        if marked == Self.rowID(key) { marked = nil }
    }
}

/// A page's sections: failure, load state, then one section per field (its description as the footer).
struct ConfigFieldsContent: View {
    let page: ConfigPage
    let store: GatewayConfigStore
    let router: SettingsRouter
    var excluding: Set<String> = []
    var showsLoadState = true

    var body: some View {
        ConfigFailureSection(store: store)
        if store.config == nil {
            if showsLoadState {
                if case .failed(let text) = store.phase {
                    LoadFailureSection(title: "Couldn’t Load Settings", text: text) { Task { await store.load(force: true) } }
                } else {
                    LoadingSection(text: "Loading settings…")
                }
            }
        } else {
            // Stress test 2026-10-28 #99 (both): other backends' image rows are hidden while they can't apply.
            let hidden = ConfigCatalog.hiddenNow(config: store.config)
            let fields = store.fields(page).filter { !excluding.contains($0.key) && !hidden.contains($0.key) }
            // [mac] Stress test 2026-10-28 round 7: the leaf page keeps what its card on the section's page has: Largest
            // Attachment under Image Attachments, and the section's footer (Shell, Local & Private URLs lost it).
            let limitRow = DeviceWord.isMac && page.key == MacAttachmentLimitRow.page
            if DeviceWord.isMac {
                // [mac] Stress test 2026-10-28 #94: one card of fields drawn in place, each with its help under its
                // control, instead of a card per setting with its help between.
                if !fields.isEmpty || limitRow {
                    // [mac] Stress test 2026-10-28 round 8: the section's footer only on the leaf that is the section's
                    // last card, where the section's page shows it (Behavior said "…what it does with attachments" and
                    // Checkpoints "…what it keeps private"). The cards are the section page's own (`flattened`).
                    // [mac] Stress test 2026-10-31: only for a section drawn flat; a section that lists its pages has
                    // its footer under that list, so Advanced's last page alone carried "Limits and tools for power users".
                    if showsLoadState, let section = ConfigCatalog.sections.first(where: { $0.id == page.section }),
                       ConfigScreens.flattensOnMac(section),
                       section.pages.filter({ !store.fields($0).isEmpty || $0.key == MacAttachmentLimitRow.page }).last?.key == page.key {
                        Section {
                            macRows(fields, limitRow: limitRow)
                        } footer: { HQSectionFooter {
                            Text(ConfigSectionView.footer(section.id, defaultBot: router.services.bots.first { $0.id == "default" }?.name,
                                                          otherBots: ((router.services as? SettingsServices)?.rosterCount ?? 0) > 1))
                                .accessibilityIdentifier("config-section.\(section.id).footer")
                        } }
                    } else {
                        Section { macRows(fields, limitRow: limitRow) }
                    }
                }
            }
            // [mac-audit] Owner 2026-11-02 #7: only on a page with no rows at all. A page that draws some of its keys
            // itself (`excluding`: Main Model's Model, Reasoning Effort and Fast Mode) said "nothing to change" right
            // under those controls.
            if fields.isEmpty, !limitRow, showsLoadState, excluding.isEmpty {
                Section {
                    Text("Hermes has nothing to change on this page.")
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 6)
                }
            }
            ForEach(DeviceWord.isMac ? [] : fields) { field in
                Section {
                    ConfigFieldRow(field: field, store: store, router: router)
                } footer: { HQSectionFooter {
                    if let description = field.description { Text(description) }
                } }
            }
        }
    }
}

extension ConfigFieldsContent {
    /// [mac] The page's fields drawn in place, and Largest Attachment on Attachments.
    @ViewBuilder fileprivate func macRows(_ fields: [ConfigFieldModel], limitRow: Bool) -> some View {
        ForEach(fields) { field in MacConfigFieldRow(field: field, store: store, router: router) }
        if limitRow { MacAttachmentLimitRow() }
    }
}

/// One field: a switch inline, anything else a value row that opens its editor.
struct ConfigFieldRow: View {
    let field: ConfigFieldModel
    let store: GatewayConfigStore
    let router: SettingsRouter
    /// A switch's second line (the Voice pages show a switch's description here, not as a footer).
    var subtitle: String? = nil

    var body: some View {
        Group {
            if field.control == .toggle {
                SwitchRow(title: field.label, subtitle: subtitle, isOn: Binding(
                    get: { field.value?.bool ?? false },
                    set: { on in
                        Haptics.play(.selection)
                        store.set(field.key, .bool(on))
                    }))
            } else {
                // [mac] Stress test 2026-10-28 #95, #101: numbers grouped and in their units, an empty value "None".
                ValueRow(title: field.label, value: DeviceWord.isMac ? ConfigUnits.summary(field) : ConfigRenderer.summary(field)) {
                    ConfigScreens.openField(field.key, store: store, router: router)
                }
            }
        }
        .accessibilityIdentifier("config-field.\(field.key)")
        .contextMenu {
            if field.canReset {
                Button("Reset to Default", systemImage: "arrow.uturn.backward") {
                    Haptics.play(.selection)
                    store.reset(field.key)
                }
            }
        }
    }
}

// MARK: - A field's editor

struct ConfigFieldEditor: View {
    let key: String
    let store: GatewayConfigStore
    @State private var text = ""
    @State private var items: [String] = []
    @State private var invalid: String?
    /// The text as loaded: an untouched field is never checked or reported.
    @State private var loaded = ""
    @State private var started = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var field: ConfigFieldModel? { store.field(key) }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if let field {
                editor(field)
                if let description = field.description {
                    Section { } footer: { HQSectionFooter { Text(description) }}
                }
                if field.defaultValue != nil {
                    Section {
                        Button("Reset to Default") {
                            Haptics.play(.selection)
                            store.reset(key)
                            load(store.field(key))
                        }
                        .disabled(!field.canReset)
                        .accessibilityIdentifier("config-editor.reset")
                    } footer: { HQSectionFooter {
                        Text("Default: \(defaultText(field))")
                    } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .onAppear {
            guard !started, field != nil else { return }
            started = true
            load(field)
        }
        .onChange(of: field != nil) { _, ready in
            guard ready, !started else { return }
            started = true
            load(field)
        }
        .task { await store.load() }
        // UX #109: checked as it's typed, so the refusal is under the field while it can still be fixed.
        .onChange(of: text) { _, now in
            guard let field, now != loaded else { invalid = nil; return }
            invalid = problem(field)
        }
        .onDisappear {
            commit()
            // Leaving with something that can't be saved says so, instead of dropping the edit unseen.
            if let invalid, let field, text != loaded { notSaved(field.label, reason: invalid) }
        }
        .accessibilityIdentifier("config-editor.\(key)")
    }

    private func defaultText(_ field: ConfigFieldModel) -> String {
        guard let value = field.defaultValue else { return "None" }
        var shown = field
        shown.value = value
        let summary = ConfigRenderer.summary(shown)
        return summary.isEmpty ? "None" : summary
    }

    private func load(_ field: ConfigFieldModel?) {
        guard let field else { return }
        switch field.control {
        case .list: items = field.value?.array?.map { ConfigText.text($0) } ?? []
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            text = field.value.flatMap { try? String(decoding: encoder.encode($0), as: UTF8.self) } ?? ""
        default: text = ConfigText.text(field.value)
        }
        loaded = text
        invalid = nil
    }

    @ViewBuilder
    private func editor(_ field: ConfigFieldModel) -> some View {
        switch field.control {
        case .choice(let options, let free, let searchable):
            choices(field, options: options, free: free, searchable: searchable)
        case .number:
            Section {
                TextField(DeviceWord.isMac ? ConfigUnits.none : "Not Set", text: $text)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .onSubmit(commit)
                    .accessibilityIdentifier("config-editor.field")
                    // [talk] On the field, not on the section: a section hands its modifiers to its footer too, and
                    // the number pad then showed Done twice as soon as a refusal was written under the field.
                    .numberPadDone(commit)   // [diagnostics] the shared bar (App/Kit/NumberPadDone.swift)
            } footer: { HQSectionFooter {
                if let invalid { Text(invalid).foregroundStyle(Color.hqRed) }
            } }
        case .text:
            Section {
                TextField(DeviceWord.isMac ? ConfigUnits.none : "Not Set", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(commit)
                    .submitLabel(.done)
                    .accessibilityIdentifier("config-editor.field")
            }
        case .longText, .json:
            Section {
                TextEditor(text: $text)
                    .font(field.control == .json ? .footnote.monospaced() : .body)
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .accessibilityIdentifier("config-editor.field")
            } footer: { HQSectionFooter {
                if let invalid { Text(invalid).foregroundStyle(Color.hqRed) }
            } }
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { commit(); focused = false } } }
        case .list:
            Section {
                ForEach(items.indices, id: \.self) { index in
                    HStack {
                        TextField("Item", text: Binding(get: { index < items.count ? items[index] : "" },
                                                        set: { if index < items.count { items[index] = $0 } }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(commit)
                            .accessibilityIdentifier("config-editor.item-\(index)")
                        MacRemoveButton(identifier: "config-editor.remove-\(index)") {
                            guard index < items.count else { return }
                            items.remove(at: index)
                            commit()
                        }
                    }
                }
                .onDelete { offsets in
                    Haptics.play(.selection)   // as a word fix's removal
                    items.remove(atOffsets: offsets)
                    commit()
                }
                Button {
                    items.append("")
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .accessibilityIdentifier("config-editor.add-item")
            } footer: { HQSectionFooter {
                Text(items.isEmpty ? "Nothing listed."
                     : DeviceWord.isMac ? "Click the red button to remove an item." : "Swipe left on an item to remove it.")
            } }
        case .toggle:
            SwitchRow(title: field.label, isOn: Binding(get: { field.value?.bool ?? false }, set: { store.set(key, .bool($0)) }))
        case .fallbackModels:
            EmptyView()
        }
    }

    @ViewBuilder
    private func choices(_ field: ConfigFieldModel, options: [String], free: Bool, searchable: Bool) -> some View {
        if free {
            Section {
                TextField("Custom", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                    .accessibilityIdentifier("config-editor.field")
            } footer: { HQSectionFooter {
                Text("Type any name, or pick a suggestion.")
            } }
        }
        if searchable {
            Section {
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("config-editor.search")
            }
        }
        let current = ConfigText.text(field.value)
        let shown = query.isEmpty ? options : options.filter {
            ConfigRenderer.optionLabel(key: key, $0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query)
        }
        Section {
            ForEach(shown, id: \.self) { option in
                Button {
                    Haptics.play(.selection)
                    store.set(key, ConfigRenderer.choiceValue(key: key, option, current: field.value))
                    text = option
                } label: {
                    // [mac] Stress test 2026-10-28 #51: a radio group on the Mac (HQOptionRowLabel).
                    HQOptionRowLabel(title: ConfigRenderer.optionLabel(key: key, option), selected: option == current)
                }
                .accessibilityAddTraits(option == current ? .isSelected : [])
                .accessibilityIdentifier("config-option.\(option.isEmpty ? "none" : option)")
                .hqRadioRow()   // [mac] Stress test 2026-10-28 #51 (round 6)
            }
        } footer: { HQSectionFooter {
            if shown.isEmpty { Text("No matches.") }
        } }
    }

    /// Writes what was typed (numbers checked, JSON parsed; nothing written while it's invalid or unchanged).
    private func commit() {
        guard let field else { return }
        let next: JSONValue?
        if let problem = problem(field) {
            invalid = problem
            return
        }
        switch field.control {
        case .number:
            guard let number = ConfigRenderer.numberValue(text) else { return }
            next = number
        case .text, .longText:
            next = .string(text)
        case .choice(_, let free, _):
            guard free else { return }
            next = .string(text.trimmingCharacters(in: .whitespaces))
        case .json:
            guard let data = text.data(using: .utf8), let parsed = try? JSONValue.parse(data) else { return }
            next = parsed
        case .list:
            next = .array(items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { .string($0) })
        case .toggle, .fallbackModels:
            next = nil
        }
        invalid = nil
        guard let next, !ConfigRenderer.same(next, field.value) else { return }
        if ConfigPath.clearsEnabledToolsets(.object(["toolsets": field.value ?? .null]), .object(["toolsets": next])) {
            confirmToolsetsWipe(next)
            return
        }
        store.set(key, next)
    }

    /// Why what's typed can't be saved (nil when it can): a number that isn't one or is out of range, or bad JSON.
    private func problem(_ field: ConfigFieldModel) -> String? {
        switch field.control {
        case .number:
            guard let number = ConfigRenderer.numberValue(text) else { return "Type a number." }
            // [talk] Max Dictation Length takes 1 to 600 (docs/spec/3x-talk.md §9.2).
            if case .number(let typed) = number { return VoiceSettingsCatalog.numberProblem(key: key, value: typed) }
            return nil
        case .json:
            guard let data = text.data(using: .utf8), (try? JSONValue.parse(data)) != nil else {
                return "That isn’t valid JSON, so it wasn’t saved."
            }
            return nil
        default:
            return nil
        }
    }

    /// The page has gone, so the refusal is an alert over whatever is showing now.
    private func notSaved(_ label: String, reason: String) {
        let presenter = UIApplication.shared.hqKeyWindow?.rootViewController   // [mac] the Settings window when it's in front (Mac polish #36)
        guard let host = FailureAlert.topmost(presenter) else { return }
        Haptics.play(.error)
        let alert = UIAlertController(title: "\(label) Wasn’t Saved", message: reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        host.present(alert, animated: true)
    }

    private func confirmToolsetsWipe(_ next: JSONValue) {
        let presenter = UIApplication.shared.hqKeyWindow?.rootViewController   // [mac] the Settings window when it's in front (Mac polish #36)
        TextPrompt.confirm(title: "Remove All Tool Groups?",
                           message: "This turns off memory, terminal, web search, subagents and most other tools until you turn them on again.",
                           action: "Remove All", from: presenter) { [store, key] in
            store.set(key, next)
        }
    }
}

/// [mac] Stress test 2026-10-28 #81, round 2: Largest Attachment sat on the Settings root while Image Attachments sat
/// in Chat Behavior › Attachments. On the Mac (where Chat Behavior draws its pages as cards) it is a row of that card;
/// it is still kept on this Mac, never written to Hermes. The root keeps it only while no gateway is connected.
struct MacAttachmentLimitRow: View {
    static let page = "chat.attachments"
    @State private var megabytes = AttachmentLimit.megabytes

    var body: some View {
        MacFormRow(label: "Largest Attachment", help: AttachmentLimit.footer()) {
            MacIntField(value: Binding(get: { megabytes }, set: { value in
                AttachmentLimit.megabytes = value
                megabytes = AttachmentLimit.megabytes
            }), range: AttachmentLimit.range, unit: "MB", label: "Largest Attachment")
        }
        .accessibilityIdentifier("settings.attachment-limit")
        .onReceive(NotificationCenter.default.publisher(for: AttachmentLimit.didChange)) { _ in
            megabytes = AttachmentLimit.megabytes
        }
    }
}
