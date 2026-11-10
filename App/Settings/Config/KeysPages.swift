// Settings › Providers (sign-ins and API keys) and Settings › Keys (tool keys and other gateway keys), as the web app
// shows them (`settings-ios-list.tsx` EnvSwitchRow / envKeyLabel, `keys-settings.tsx`, `providers-settings.tsx`).
// A set key comes back redacted; Show reads its value once (`POST /api/env/reveal`) and the page alone keeps it while it
// is open. Values are never logged.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class EnvKeysModel {
    var vars: [EnvVarInfo] = []
    var loaded = false
    var loadError: String?
    var failure: String?
    /// What failed, to send again from Try Again (nil when there's nothing to repeat, e.g. a read-only gateway).
    var lastAction: (@MainActor () async -> Void)?
    var busy: Set<String> = []
    /// Values read with Show, while this page is open (never stored elsewhere).
    var revealed: [String: String] = [:]
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool
    /// Switch values written on this phone this run (the gateway only ever answers redacted).
    @ObservationIgnored static var written: [String: Bool] = [:]
    // [morepages] The same key page over another store (Messaging's platform keys, docs/spec/3x-morepages.md §12):
    // such keys are read, saved and removed through `store`, and are never shown again (no Show).
    @ObservationIgnored var store: EnvKeyStore?
    var canReveal: Bool { store == nil }

    init(api: GatewaySettingsAPI?, readOnly: Bool) {
        self.api = api
        self.readOnly = readOnly
    }

    func load() async {
        if let store {   // [morepages]
            do { vars = try await store.load(); loaded = true; loadError = nil } catch {
                AppLog.note("settings", "keys load (store) failed: \(type(of: error))")
                loadError = SettingsErrorText.load(error)
            }
            return
        }
        guard let api else { return }
        do {
            vars = try await api.env()
            loaded = true
            loadError = nil
        } catch {
            AppLog.note("settings", "keys load failed: \(type(of: error))")
            loadError = SettingsErrorText.load(error)
        }
    }

    func info(_ key: String) -> EnvVarInfo? { vars.first { $0.key == key } }

    /// Plain values read on earlier visits this run (per gateway): a port or an on/off isn't read again each time the
    /// page opens, as the gateway allows only a few reads a minute. Never secrets (`EnvKeys.readsValueItself`).
    @ObservationIgnored private static var plainValues: [String: String] = [:]

    /// Stress test 2026-10-28 #84, round 2 (both): reads the set numbers and on/offs of `keys` so their rows show the
    /// value ("8642", a switch) instead of "Set". A few per visit; a refused read leaves the row as it was, quietly.
    func readPlainValues(_ keys: [EnvVarInfo]) async {
        guard canReveal, let api else { return }
        var reads = 0
        for info in keys where EnvKeys.readsValueItself(info) && revealed[info.key] == nil {
            let memo = Self.memoKey(info.key, api: api)
            if let known = Self.plainValues[memo] { revealed[info.key] = known; continue }
            guard reads < EnvKeys.readsPerOpen else { continue }
            reads += 1
            do {
                let value = try await api.revealEnv(info.key)
                revealed[info.key] = value
                Self.plainValues[memo] = value
            } catch {
                AppLog.note("settings", "plain key read failed: \(type(of: error))")
            }
        }
    }

    func reveal(_ key: String) async {
        guard let api else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let start = ContinuousClock.now
        do {
            revealed[key] = try await api.revealEnv(key)
            AppLog.trace("settings", "key revealed in \(AppLog.ms(since: start)) ms")
        } catch {
            AppLog.note("settings", "key reveal failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            failure = "Couldn’t show \(EnvKeys.title(info(key) ?? EnvVarInfo(key: key))). \(SettingsErrorText.save(error))"
            lastAction = { [weak self] in await self?.reveal(key) }
        }
    }

    @discardableResult
    func save(_ key: String, _ value: String) async -> Bool {
        guard !readOnly else { failure = BotWriteError.readOnlyReason; lastAction = nil; return false }
        let start = ContinuousClock.now
        if let store {   // [morepages]
            busy.insert(key)
            defer { busy.remove(key) }
            do {
                try await store.save(key, value)
                AppLog.trace("settings", "key saved (store) in \(AppLog.ms(since: start)) ms")
                failure = nil; await load(); return true
            } catch {
                AppLog.note("settings", "key save (store) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                failure = SettingsErrorText.save(error)
                lastAction = { [weak self] in _ = await self?.save(key, value) }
                return false
            }
        }
        guard let api else { return false }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await api.setEnv(key, value: value)
            AppLog.note("settings", "key saved in \(AppLog.ms(since: start)) ms")
            // #84 round 2: a plain value just written is known, so its row shows it; a secret is never kept.
            let plain = info(key).map { EnvKeys.readsValueItself(EnvVarInfo(key: $0.key, description: $0.description,
                                                                             isPassword: $0.isPassword, isSet: true)) } ?? false
            revealed[key] = plain ? value : nil
            Self.plainValues[Self.memoKey(key, api: api)] = plain ? value : nil
            failure = nil
            await load()
            return true
        } catch {
            AppLog.note("settings", "key save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            failure = SettingsErrorText.save(error)
            lastAction = { [weak self] in _ = await self?.save(key, value) }
            return false
        }
    }

    @discardableResult
    func remove(_ key: String) async -> Bool {
        guard !readOnly else { failure = BotWriteError.readOnlyReason; lastAction = nil; return false }
        let start = ContinuousClock.now
        if let store {   // [morepages]
            busy.insert(key)
            defer { busy.remove(key) }
            do {
                try await store.remove(key)
                AppLog.trace("settings", "key removed (store) in \(AppLog.ms(since: start)) ms")
                failure = nil; await load(); return true
            } catch {
                AppLog.note("settings", "key remove (store) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                failure = SettingsErrorText.save(error)
                lastAction = { [weak self] in _ = await self?.remove(key) }
                return false
            }
        }
        guard let api else { return false }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await api.deleteEnv(key)
            AppLog.note("settings", "key removed in \(AppLog.ms(since: start)) ms")
            revealed[key] = nil; Self.plainValues[Self.memoKey(key, api: api)] = nil
            failure = nil
            await load()
            return true
        } catch {
            AppLog.note("settings", "key remove failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            failure = SettingsErrorText.save(error)
            lastAction = { [weak self] in _ = await self?.remove(key) }
            return false
        }
    }

    /// Try Again on the failure card: the write that failed, sent again (UX #201; it used to only hide the card).
    func retry() {
        let action = lastAction
        failure = nil
        lastAction = nil
        if let action { Task { await action() } }
    }

    func dismissFailure() {
        failure = nil
        lastAction = nil
    }

    /// A switch: back to its default removes the key; otherwise "true"/"false" is written.
    func setSwitch(_ info: EnvVarInfo, _ on: Bool) {
        let memo = Self.memoKey(info.key, api: api)
        let before = Self.written[memo]
        Self.written[memo] = on
        let removes = EnvKeys.switchRemoves(info, to: on)
        let again: @MainActor () async -> Void = { [weak self] in self?.setSwitch(info, on) }
        Task {
            let ok = removes ? await remove(info.key) : await save(info.key, on ? "true" : "false")
            // A removed key shows its default again (known from the list); a written one keeps the value written.
            if !ok { Self.written[memo] = before } else if removes { Self.written[memo] = nil }
            // Try Again flips the switch again, so the remembered value follows the retry too.
            if !ok, lastAction != nil { lastAction = again }
        }
    }

    static func memoKey(_ key: String, api: GatewaySettingsAPI?) -> String { "\(api?.client.account.id ?? "")\u{0}\(key)" }

    func switchState(_ info: EnvVarInfo) -> Bool? {
        EnvKeys.switchState(info, known: Self.written[Self.memoKey(info.key, api: api)] ?? EnvKeys.bool(revealed[info.key]))
    }

    /// Mac polish #98: the switch the key only matters under (`EnvKeys.parentSwitch`) is known to be off, so its row
    /// shows dimmed and held, its value untouched.
    func heldOff(_ key: String) -> Bool {
        guard let parent = EnvKeys.parentSwitch(key).flatMap({ info($0) }) else { return false }
        return switchState(parent) == false
    }
}

extension EnvKeys {
    /// Mac polish #98: the switch a key only matters under: API Server's port, host, key and the rest under API Server
    /// (with it off its port stayed typeable). Nil for every other key.
    static func parentSwitch(_ key: String) -> String? {
        key.hasPrefix("API_SERVER_") && key != "API_SERVER_ENABLED" ? "API_SERVER_ENABLED" : nil
    }
}

// [morepages] Where the key page reads and writes when it is not Settings' own keys.
struct EnvKeyStore {
    var load: () async throws -> [EnvVarInfo]
    var save: (String, String) async throws -> Void
    var remove: (String) async throws -> Void
    var removeFooter: (String) -> String
}

// MARK: - A key's row

struct EnvKeyRow: View {
    let info: EnvVarInfo
    let model: EnvKeysModel
    let router: SettingsRouter
    var title: String? = nil
    /// [provider-add] Settings › Providers' API keys: a set key can be removed from the list (swipe, or the row's menu).
    var removable = false

    var body: some View {
        // [mac] Mac polish #98: held while the switch it depends on is off (API Server's port with API Server off); the
        // Mac's fields and buttons fade themselves. iPhone and iPad keep their rows as they were.
        let held = DeviceWord.isMac && model.heldOff(info.key)
        row(held: held)
            .disabled(held)
    }

    @ViewBuilder private func row(held: Bool) -> some View {
        let label = title ?? EnvKeys.title(info)
        if EnvKeys.isSwitch(info) {
            EnvSwitchRow(info: info, label: label, model: model)
        } else if EnvNumberRow.applies(info, model: model) {
            EnvNumberRow(info: info, label: label, model: model, router: router)
        } else {
            Button {
                router.push(label, EnvKeyEditor(key: info.key, label: label, model: model))
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        // [mac] Held, the label in the secondary colour, as a held form row's (`MacFormRow`).
                        Text(label).foregroundStyle(held && DeviceWord.isMac ? Color.hqLabel2 : Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        Text(stateText).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    SettingsChevron()  // [mac] Stress test 2026-10-28 #51: no › on the Mac
                }
                .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("env-key.\(info.key)")
            // [provider-add] Owner 2026-11-04 ("i need to remove them"): Remove Key from the list, asked first as on
            // its page. Red, not the destructive role (it animates the row out before the confirm).
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if canRemove { Button("Remove") { EnvKeyEditor.confirmRemove(info.key, label: label, model: model) }.tint(.red) }
            }
            // A mouse has no swipe: the same on a right-click (and a touch and hold).
            .contextMenu {
                if canRemove {
                    Button("Remove Key…", systemImage: "trash", role: .destructive) {
                        EnvKeyEditor.confirmRemove(info.key, label: label, model: model)
                    }
                }
            }
        }
    }

    private var canRemove: Bool { removable && info.isSet && !model.readOnly && !model.busy.contains(info.key) }

    private var stateText: String {
        guard info.isSet else { return EnvKeyRow.unsetWord }
        if !info.isPassword, let value = model.revealed[info.key] { return value }
        return EnvKeys.rowPreview(info).map { "Set · \($0)" } ?? "Set"
    }

    /// A key with nothing saved. [mac] Stress test 2026-10-28 #101: "None", the word every other Settings page uses for
    /// an empty value on the Mac (`ConfigUnits.none`); the iPhone's pages all say "Not Set", so it does too.
    static var unsetWord: String { DeviceWord.isMac ? ConfigUnits.none : "Not Set" }
}

/// [mac] Stress test 2026-10-28 #84, #101: a plain number key (a port, a timeout) is typed in place on the Mac, as the
/// config pages' numbers are (`MacNumberField`), instead of a pushed page with Show and Save. It shows the value read when
/// the page opens (`readPlainValues`) and saves through the page's own path (`EnvKeysModel.save`) on Return or when the
/// field is left, only when it changed. Secrets and text keys keep their page; Control-click opens it here too.
struct EnvNumberRow: View {
    let info: EnvVarInfo
    let label: String
    let model: EnvKeysModel
    let router: SettingsRouter
    @State private var text = ""
    @State private var loaded = ""
    @State private var problem: String?
    @FocusState private var focused: Bool
    /// Mac polish #98: held (API Server off), the field fades as `MacNumberField`'s does.
    @Environment(\.isEnabled) private var enabled

    static func applies(_ info: EnvVarInfo, model: EnvKeysModel) -> Bool {
        DeviceWord.isMac && model.canReveal && !info.isPassword && EnvKeys.isNumber(info)
    }

    var body: some View {
        // Set but not read yet (the gateway allows a few reads a minute): the field says so instead of looking empty.
        let prompt = info.isSet && model.revealed[info.key] == nil ? "Set" : ConfigUnits.none
        // [mac] Stress test 2026-10-28 round 7: a form row (`MacFormRow`), the field in the control column the config
        // pages use, not at the trailing edge.
        // [mac] Stress test 2026-10-28 round 8: the row is the form row itself (its one height; the field's own width and
        // height, leading text, as `MacNumberField`), with a problem under the field as the config numbers show theirs.
        MacFormRow(label: label) {
            VStack(alignment: .leading, spacing: 3) {
                TextField(prompt, text: $text, prompt: MacField.prompt(prompt))
                    .multilineTextAlignment(.leading)
                    .monospacedDigit()
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .hqMacFieldBox()
                    .frame(width: MacForm.numberWidth)
                    .opacity(enabled ? 1 : 0.45)
                    .focused($focused)
                    .onSubmit(save)
                    .disabled(model.readOnly || model.busy.contains(info.key))
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("env-number.\(info.key)")
                if let problem {
                    Text(problem).font(MacType.footnoteFont).foregroundStyle(Color.hqRed)
                }
            }
        }
        .contextMenu {
            Button("Open \(label)…") { router.push(label, EnvKeyEditor(key: info.key, label: label, model: model)) }
        }
        .onAppear { load(model.revealed[info.key]) }
        .onChange(of: model.revealed[info.key]) { _, now in if !focused { load(now) } }
        .onChange(of: focused) { _, now in if !now { save() } }
        .onDisappear(perform: save)
    }

    private func load(_ value: String?) {
        text = value ?? ""
        loaded = text
        problem = nil
    }

    private func save() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed != loaded else { problem = nil; return }
        // An emptied field writes nothing (Remove Key is on the key's page); the value read stays.
        guard !typed.isEmpty else { text = loaded; problem = nil; return }
        guard Double(typed) != nil else { problem = "Type a number."; return }
        problem = nil
        let before = loaded
        loaded = typed
        Task {
            if await model.save(info.key, typed) { Haptics.play(.success) } else { loaded = before }
        }
    }
}

/// An on/off key (`EnvSwitchRow`): a switch when its state is known (a set one is read when the page opens), else the
/// same row with a pop-up where the switch would be: Show Current Value, On, Off.
/// Stress test 2026-10-28 #84 (both): Other Keys mixed four row types (a switch with its note under it, so the switch sat
/// on the title line; bare "Show" links; a blue "Not Set" that read as a button). Now a known switch carries its note as
/// the row's subtitle, centred against it, and an unknown one is drawn as a key row with a pop-up glyph.
struct EnvSwitchRow: View {
    let info: EnvVarInfo
    let label: String
    let model: EnvKeysModel

    var body: some View {
        let state = model.switchState(info)
        let base = EnvKeys.switchDescription(info.description).trimmingCharacters(in: .whitespaces)
        if let state {
            SwitchRow(title: label, subtitle: base.isEmpty ? nil : base, isOn: Binding(get: { state }, set: { on in
                Haptics.play(.selection)
                model.setSwitch(info, on)
            }), disabled: model.busy.contains(info.key))
            .padding(.vertical, base.isEmpty || DeviceWord.isMac ? 0 : 4)   // [mac] Stress test 2026-10-28 round 8: the form's row room
            .accessibilityIdentifier("env-switch.\(info.key)")
        } else {
            // Stress test 2026-10-28 #84, round 2 (both): laid out as a switch row (title and note on the left, the
            // control at the trailing edge), with a pop-up where the switch would be. The note was the Menu's own label,
            // so its second line was centred and pushed in by a space; it is now a plain leading-aligned text.
            let note = EnvKeys.unknownNote(info, revealed: model.revealed[info.key])
            let text = [!base.isEmpty && !".!?".contains(base.last!) ? base + "." : base, note].filter { !$0.isEmpty }.joined(separator: " ")
            let word = info.isSet ? "Set" : EnvKeyRow.unsetWord   // [mac] #101: "None" on the Mac
            if DeviceWord.isMac {
                // [mac-audit] Owner 2026-11-02 (round-4 #13): the pop-up read "None", which isn't one of its items (Show
                // Current Value, On, Off). Unset, the key is whatever Hermes does by default, and the pop-up says so.
                let shown = info.isSet ? word : "Default"
                // [mac] Stress test 2026-10-28 round 7: a form row: the bordered pop-up in the control column and the
                // note under the label across the row (the borderless "None ⌃" sat at the trailing edge and the note
                // wrapped short beside it).
                MacFormRow(label: label, help: text.isEmpty ? nil : text) {
                    unknownMenu(word: shown) { MacPopUpFace(text: shown) }
                        .menuStyle(.button)
                        .buttonStyle(MacPopUpButtonStyle())   // [mac] Stress test 2026-10-28 round 8: no second fade
                }
            } else {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    if !text.isEmpty {
                        Text(text).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                unknownMenu(word: word) {
                    HStack(spacing: 4) {
                        Text(word)
                        Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption).weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.vertical, 4)
            }
        }
    }

    /// The unknown switch's menu (Show Current Value, On, Off) with the face each platform draws.
    private func unknownMenu<Face: View>(word: String, @ViewBuilder face: () -> Face) -> some View {
        Menu {
            if info.isSet, model.revealed[info.key] == nil {
                Button("Show Current Value") { Task { await model.reveal(info.key) } }
                    .accessibilityIdentifier("env-switch.show.\(info.key)")
                Divider()
            }
            Button("On") { model.setSwitch(info, true) }
            Button("Off") { model.setSwitch(info, false) }
        } label: {
            face()
        }
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(word)
        .accessibilityIdentifier("env-switch.menu.\(info.key)")
    }
}

// MARK: - A key's page

struct EnvKeyEditor: View {
    let key: String
    let label: String
    let model: EnvKeysModel
    @State private var draft = ""
    @State private var saved = false
    @Environment(\.openURL) private var openURL

    private var removeFooter: String { Self.removeFooter(key, model: model) }

    static func removeFooter(_ key: String, model: EnvKeysModel) -> String {
        model.store?.removeFooter(key)   // [morepages]
            ?? "Removes \(key) from \(HostWord.phrase). Tools that need it stop working until you add it again."
    }

    /// UX #203: asked first, as Capabilities does; the saved value can't be got back from here. [provider-add] Also from
    /// the key's row on Settings › Providers.
    static func confirmRemove(_ key: String, label: String, model: EnvKeysModel) {
        let presenter = UIApplication.shared.hqKeyWindow?.rootViewController   // [mac] the Settings window when it's in front (Mac polish #36)
        TextPrompt.confirm(title: "Remove \(label)?", message: removeFooter(key, model: model), action: "Remove Key", from: presenter) {
            Task { if await model.remove(key) { Haptics.play(.success) } }
        }
    }

    var body: some View {
        let info = model.info(key) ?? EnvVarInfo(key: key)
        List { Group {
            if let failure = model.failure {
                SaveFailureSection(text: failure, detail: nil, retry: model.lastAction == nil ? nil : { model.retry() },
                                   dismiss: { model.dismissFailure() })
            }
            Section {
                LabeledContent("Status", value: info.isSet ? "Set on Your Gateway" : "Not Set")
                if info.isSet {
                    if let value = model.revealed[key] {
                        Text(value)
                            .font(Font.hq(.footnote).monospaced())
                            .foregroundStyle(Color.hqLabel)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("env-editor.value")
                        Button("Copy") {
                            UIPasteboard.general.string = value
                            Haptics.play(.success)
                        }
                        Button("Hide") { model.revealed[key] = nil }
                    } else {
                        if let preview = EnvKeys.preview(info.redactedValue) {
                            LabeledContent("Saved", value: preview)
                        }
                        if model.canReveal {   // [morepages]
                            Button(model.busy.contains(key) ? "Showing…" : "Show") { Task { await model.reveal(key) } }
                                .disabled(model.busy.contains(key))
                                .accessibilityIdentifier("env-editor.show")
                        }
                    }
                }
            } header: { HQSectionLabel {
                Text(key).textCase(nil).font(Font.hq(.footnote).monospaced())
            } } footer: { HQSectionFooter {
                if info.isSet, model.revealed[key] == nil, model.canReveal {   // [morepages]
                    Text("Show a saved key a few times a minute at most; each look is logged.")
                }
            } }
            Section {
                Group {
                    if info.isPassword {
                        SecureField(info.isSet ? "New value" : "Value", text: $draft)
                    } else {
                        TextField(info.isSet ? "New value" : "Value", text: $draft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("env-editor.field")
                Button(saved ? "Saved" : "Save") {
                    let value = draft
                    Task {
                        if await model.save(key, value) {
                            draft = ""
                            saved = true
                            Haptics.play(.success)
                        }
                    }
                }
                .disabled(draft.isEmpty || model.busy.contains(key))
                .accessibilityIdentifier("env-editor.save")
            } header: { HQSectionLabel {
                Text(info.isSet ? "Replace" : "Add")
            } } footer: { HQSectionFooter {
                Text(EnvKeys.description(info.description))
            } }
            if let url = info.url.flatMap(URL.init(string:)), url.scheme == "https" {
                Section {
                    Button("Get a Key") { openURL(url) }
                }
            }
            if info.isSet {
                Section {
                    // UX #203: asked first, as Capabilities does; the saved value can't be got back from here.
                    Button("Remove Key", role: .destructive) {
                        Self.confirmRemove(key, label: label, model: model)
                    }
                    .accessibilityIdentifier("env-editor.remove")
                } footer: { HQSectionFooter {
                    Text(removeFooter)
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.failure)
        .onChange(of: draft) { _, _ in saved = false }
        .environment(\.openURL, OpenURLAction { url in .systemAction(url, prefersInApp: true) })
        .onDisappear { draft = "" }
    }
}

// MARK: - Keys page

struct KeysPageView: View {
    let router: SettingsRouter
    @State private var model: EnvKeysModel

    init(router: SettingsRouter) {
        self.router = router
        _model = State(initialValue: EnvKeysModel(api: router.gatewaySettings?.settingsAPI,
                                                  readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false))
    }

    var body: some View {
        List { Group {
            if let failure = model.failure {
                SaveFailureSection(text: failure, detail: nil, retry: model.lastAction == nil ? nil : { model.retry() },
                                   dismiss: { model.dismissFailure() })
            }
            if let error = model.loadError, !model.loaded {
                LoadFailureSection(title: "Couldn’t Load Keys", text: error) { Task { await model.load() } }
            } else if !model.loaded {
                LoadingSection()
            } else {
                let tools = EnvKeys.toolKeys(model.vars)
                let other = EnvKeys.otherKeys(model.vars)
                Section {
                    if tools.isEmpty { Text("No tool keys on this gateway.").foregroundStyle(Color.hqLabel2) }
                    ForEach(tools, id: \.key) { EnvKeyRow(info: $0, model: model, router: router) }
                } header: { HQSectionLabel {
                    Text("Tools")
                } } footer: { HQSectionFooter {
                    Text("Keys your bots’ tools use (web search, image generation, voice…).")
                } }
                Section {
                    if other.isEmpty { Text("No other keys on this gateway.").foregroundStyle(Color.hqLabel2) }
                    ForEach(other, id: \.key) { EnvKeyRow(info: $0, model: model, router: router) }
                } header: { HQSectionLabel {
                    Text("Other Keys")
                } } footer: { HQSectionFooter {
                    // Stress test 2026-10-28 #100, round 2 (both): where keys are saved is said once, at the bottom of the page.
                    Text("Other settings stored as keys, like proxies and messaging defaults. Every key on this page is saved on \(HostWord.phrase).")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.failure)
        // Stress test 2026-10-28 #84, round 2 (both): set numbers and on/off keys are read so their rows show the value.
        .task { await model.load(); await model.readPlainValues(model.vars) }
        .refreshable { await model.load(); await model.readPlainValues(model.vars) }
        .accessibilityIdentifier("keys.list")
    }
}

// [provider-manager] Settings › Providers is `ProvidersPageView` in ProviderManagerPages.swift.
