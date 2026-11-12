// The vault behind Passwords (the page is PasswordsPage.swift; `vendor/.../settings/vault-settings.tsx`: `vault.list`, `vault.add`, `vault.remove`,
// `vault.sources`, `vault.source.set`, `vault.unlock`, `vault.lock`), Settings › Billing (read-only, `billing.state`,
// amounts in one currency format as `iosBillingView` shows them) and Settings › Sessions (Auto-archive stale chats:
// `sessions.auto_archive` / `auto_archive_days` as a sparse config write; Default Project Folder when the app has
// new-chat folders to apply it to).

import Observation
import SwiftUI
import UIKit

// MARK: - Vault

nonisolated struct VaultItem: Identifiable, Sendable, Hashable {
    var id: String
    var kind: String
    var label: String
    var origin: String?
    var identifier: String?
    var backend: String?
    var created: String

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string else { return nil }
        self.id = id
        kind = value["kind"]?.string ?? "login"
        label = value["label"]?.string ?? id
        origin = RosterText.trimmed(value["origin"])
        identifier = RosterText.trimmed(value["identifier"])
        backend = value["backend"]?.string
        created = value["created_at"]?.string ?? ""
    }

    var kindTitle: String {
        switch kind {
        case "login": "Login"
        case "payment": "Card"
        case "address": "Address"
        default: ConfigText.pretty(kind)
        }
    }
}

nonisolated struct VaultSource: Identifiable, Sendable, Hashable {
    /// The password manager row's subtitle: what its switch does, then whether it can fill now (stress test #87).
    static func subtitle(_ source: VaultSource) -> String {
        guard source.installed else { return "Not installed on \(HostWord.phrase)" }
        guard source.enabled else { return "Off: bots don’t fill logins from it." }
        return source.unlocked ? "On: bots fill logins from it. Unlocked." : "On, but locked: unlock it so bots can fill logins."
    }


    var id: String
    var name: String
    var enabled: Bool
    var needsUnlock: Bool
    var unlocked: Bool
    var installed: Bool

    init?(_ value: JSONValue) {
        guard let id = value["name"]?.string else { return nil }
        self.id = id
        name = RosterText.trimmed(value["display_name"]) ?? ConfigText.pretty(id)
        enabled = value["enabled"]?.bool ?? false
        needsUnlock = value["needs_unlock"]?.bool ?? false
        unlocked = value["unlocked"]?.bool ?? false
        installed = value["installed"]?.bool ?? false
    }
}

@MainActor @Observable
final class VaultModel {
    var items: [VaultItem] = []
    var sources: [VaultSource] = []
    var loaded = false
    var loadError: String?
    var failure: String?
    /// The write that failed, for Try Again (UX #201). Never an unlock or an add: their passwords and secrets aren't kept for a retry.
    var lastWrite: (method: String, params: JSONValue)?
    @ObservationIgnored let api: GatewaySettingsAPI?
    @ObservationIgnored let readOnly: Bool

    init(api: GatewaySettingsAPI?, readOnly: Bool) {
        self.api = api
        self.readOnly = readOnly
    }

    func load() async {
        guard let api else { return }
        do {
            items = (try await api.rpc("vault.list")["items"]?.array ?? []).compactMap(VaultItem.init)
            sources = ((try? await api.rpc("vault.sources")["sources"]?.array) ?? []).compactMap(VaultSource.init).filter(\.needsUnlock)
            loaded = true
            loadError = nil
        } catch {
            AppLog.note("settings", "vault load failed: \(type(of: error))")
            loadError = SettingsErrorText.load(error)
        }
    }

    private func write(_ method: String, _ params: JSONValue) async -> Bool {
        guard !readOnly else { failure = BotWriteError.readOnlyReason; lastWrite = nil; return false }
        guard let api else { return false }
        let start = ContinuousClock.now
        do {
            _ = try await api.rpc(method, params)
            AppLog.trace("settings", "\(method) ok in \(AppLog.ms(since: start)) ms")
            failure = nil
            lastWrite = nil
            await load()
            return true
        } catch {
            AppLog.note("settings", "\(method) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
            failure = SettingsErrorText.save(error)
            lastWrite = method == "vault.unlock" || method == "vault.add" ? nil : (method, params)
            return false
        }
    }

    /// Try Again on the failure card: the same write, sent again.
    func retry() {
        guard let last = lastWrite else { return }
        failure = nil
        lastWrite = nil
        Task { _ = await write(last.method, last.params) }
    }

    func dismissFailure() {
        failure = nil
        lastWrite = nil
    }

    func remove(_ item: VaultItem) async -> Bool { await write("vault.remove", ["id": .string(item.id)]) }

    /// The secret goes straight into the request and is dropped with the form.
    func add(kind: String, label: String, origin: String, secret: [String: String]) async -> Bool {
        await write("vault.add", ["kind": .string(kind), "label": .string(label), "origin": .string(origin),
                                  "secret": .object(secret.mapValues { .string($0) })])
    }

    func setSource(_ source: VaultSource, enabled: Bool) async -> Bool {
        await write("vault.source.set", ["name": .string(source.id), "enabled": .bool(enabled)])
    }

    func unlock(_ source: VaultSource, password: String) async -> Bool {
        await write("vault.unlock", ["name": .string(source.id), "password": .string(password)])
    }

    func lock(_ source: VaultSource) async -> Bool { await write("vault.lock", ["name": .string(source.id)]) }

    static func validOrigin(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && !(url.host() ?? "").isEmpty
    }
}

struct VaultAddView: View {
    let model: VaultModel
    let done: () -> Void
    @State private var kind = "login"
    @State private var label = ""
    @State private var origin = "https://"
    @State private var identifier = ""
    @State private var password = ""
    @State private var cardNumber = ""
    @State private var cardName = ""
    @State private var expiry = ""
    @State private var cvc = ""
    @State private var line1 = ""
    @State private var city = ""
    @State private var postal = ""
    @State private var country = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                HQSegmentedPicker("Kind", options: [("Login", "login"), ("Card", "payment"), ("Address", "address")],
                                  selection: $kind)   // [desktoplook3]
                TextField("Name (e.g. My Bank)", text: $label).accessibilityIdentifier("vault-add.label")
                TextField("Website", text: $origin)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault-add.origin")
            } footer: { HQSectionFooter {
                Text("It’s filled only on this website.")
            } }
            switch kind {
            case "login":
                Section {
                    TextField("Email or Username", text: $identifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .accessibilityIdentifier("vault-add.identifier")
                    SecureField("Password", text: $password).textContentType(.password)
                        .accessibilityIdentifier("vault-add.password")
                } header: { HQSectionLabel { Text("Login") } }
            case "payment":
                Section {
                    TextField("Card Number", text: $cardNumber).keyboardType(.numberPad).numberPadDone()
                        .accessibilityIdentifier("vault-add.card-number")
                    TextField("Name on Card", text: $cardName)
                    TextField("Expiry (MM/YY)", text: $expiry).keyboardType(.numbersAndPunctuation)
                    SecureField("Security Code", text: $cvc).keyboardType(.numberPad).numberPadDone()
                        .accessibilityIdentifier("vault-add.cvc")
                    TextField("Billing Postal Code", text: $postal)
                } header: { HQSectionLabel { Text("Card") } }
            default:
                Section {
                    TextField("Street", text: $line1)
                    TextField("City", text: $city)
                    TextField("Postal Code", text: $postal)
                    TextField("Country", text: $country)
                } header: { HQSectionLabel { Text("Address") } }
            }
            if let error {
                Section { Text(error).foregroundStyle(Color.hqRed) }
            }
            Section {
                Button(saving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)   // ⌘Return saves, as in New Job
                    .disabled(saving)
                    .accessibilityIdentifier("vault-add.save")
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .onDisappear { password = ""; cvc = ""; cardNumber = "" }
    }

    private func save() {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give it a name."; return }
        guard VaultModel.validOrigin(origin) else { error = "Type the website’s address, starting with https://."; return }
        var secret: [String: String]
        switch kind {
        case "login":
            guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
                error = "A login needs an email or username and a password."
                return
            }
            secret = ["identifier_type": identifier.contains("@") ? "email" : "username",
                      "identifier": identifier.trimmingCharacters(in: .whitespaces), "password": password]
        case "payment":
            let parts = expiry.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            secret = ["card_number": cardNumber.replacingOccurrences(of: " ", with: ""), "cardholder_name": cardName,
                      "exp_month": parts.first ?? "", "exp_year": parts.count > 1 ? parts[1] : "", "cvc": cvc,
                      "billing_postal_code": postal]
        default:
            secret = ["address_line1": line1, "city": city, "postal_code": postal, "country": country]
        }
        error = nil
        saving = true
        let kind = self.kind, label = self.label.trimmingCharacters(in: .whitespaces), origin = self.origin.trimmingCharacters(in: .whitespaces)
        password = ""; cvc = ""
        Task {
            let ok = await model.add(kind: kind, label: label, origin: origin, secret: secret)
            saving = false
            if ok {
                Haptics.play(.success)
                done()
            } else {
                Haptics.play(.error)
                error = model.failure
            }
        }
    }
}

// MARK: - Billing (read-only)

nonisolated enum BillingText {
    /// "$1000" → "$1,000.00" (a "/mo" price keeps its form).
    static func money(_ text: String, locale: Locale = .current) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(-|−)?\$\s?(\d[\d,]*(?:\.\d+)?)(?![\d/])"#) else { return text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let digits = Range(match.range(at: 2), in: out),
                  let amount = Double(out[digits].replacingOccurrences(of: ",", with: "")),
                  let formatted = formatter.string(from: NSNumber(value: amount)) else { continue }
            let sign = match.range(at: 1).location != NSNotFound ? String(out[Range(match.range(at: 1), in: out)!]) : ""
            out.replaceSubrange(whole, with: sign + formatted)
        }
        return out
    }
}

struct BillingPageView: View {
    let router: SettingsRouter
    @State private var state: JSONValue?
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List { Group {
            if let error, state == nil {
                LoadFailureSection(title: "Couldn’t Load Billing", text: error) { Task { await load() } }
            } else if let state {
                content(state)
            } else {
                LoadingSection()
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .task { await load() }
        .refreshable { await load() }
        .environment(\.openURL, LinkOpener.openURLAction)   // [links-browser]
        .accessibilityIdentifier("billing.list")
    }

    @ViewBuilder
    private func content(_ state: JSONValue) -> some View {
        let usage = state["usage"]
        if state["free_tier_account"]?.bool == true {
            Section {
                Text("This gateway uses Nous’s free tier\(RosterText.trimmed(state["free_tier_model"]).map { " (\($0))" } ?? ""). There’s no account or balance to show.")
                    .foregroundStyle(Color.hqLabel2)
            }
        } else if state["logged_in"]?.bool != true {
            Section {
                Text(RosterText.trimmed(state["error"]) ?? "Your gateway isn’t signed in to a Nous account, so there’s no billing to show.")
                    .foregroundStyle(Color.hqLabel2)
            } footer: { HQSectionFooter {
                Text("Sign in to Nous Portal on \(HostWord.phrase) to see your balance here.")
            } }
        } else {
            Section {
                if let org = RosterText.trimmed(state["org_name"]) { InfoRow("Account", value: org) }
                if let balance = RosterText.trimmed(state["balance_display"]) {
                    InfoRow("Balance", value: BillingText.money(balance)).accessibilityIdentifier("billing.balance")
                }
                if let card = RosterText.trimmed(state["card"]?["display"]) ?? RosterText.trimmed(state["card"]?["masked"]) {
                    InfoRow("Payment Method", value: card).accessibilityIdentifier("billing.card")
                }
                if let reload = state["auto_reload"], !reload.isNull {
                    InfoRow("Auto Reload", value: reload["enabled"]?.bool == true
                                   ? BillingText.money("To \(RosterText.trimmed(reload["reload_to_display"]) ?? "")") : "Off")
                }
            } header: { HQSectionLabel {
                Text("Nous Portal")
            } }
            if let usage, usage["available"]?.bool == true {
                Section {
                    if let plan = RosterText.trimmed(usage["plan_name"]) { InfoRow("Plan", value: plan) }
                    if let renews = RosterText.trimmed(usage["renews_display"]) { InfoRow("Renews", value: renews) }
                    // Stress test 2026-10-28 #86 (both): two rows were called "Plan" ("Plus", and "$12.50 of $20.00 left").
                    if let bar = usage["plan_bar"], !bar.isNull { usageBar("Plan Allowance", bar) }
                    if let bar = usage["topup_bar"], !bar.isNull { usageBar("Top-Up", bar) }
                    if let total = RosterText.trimmed(usage["total_spendable_display"]) {
                        InfoRow("Available", value: BillingText.money(total))
                    }
                } header: { HQSectionLabel {
                    Text("Usage")
                } }
            }
        }
        // [app-store-review] Guideline 3.1.1: the plan and balance above stay read-only; no button or link to pay,
        // top up or change plan on the web.
        #if !APP_STORE
        if let portal = RosterText.trimmed(state["portal_url"]).flatMap(URL.init(string:)), portal.scheme == "https" {
            Section {
                Button("Manage on Nous Portal") { openURL(portal) }
                    .hqMacFormButton()   // [mac] Stress test 2026-10-28 #51 (review): a push button, not a link-coloured row
            } footer: { HQSectionFooter {
                Text("Change your plan, card or top-ups on the web.")
            } }
        }
        #else
        Section {
            Text("Your plan and credits are managed in your Nous account.").foregroundStyle(Color.hqLabel2)
        }
        #endif
    }

    private func usageBar(_ title: String, _ bar: JSONValue) -> some View {
        let fraction = min(1, max(0, bar["fill_fraction"]?.double ?? 0))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer()
                Text(BillingText.money("\(RosterText.trimmed(bar["remaining_display"]) ?? "") of \(RosterText.trimmed(bar["total_display"]) ?? "") left"))
                    .foregroundStyle(Color.hqLabel2)
            }
            ProgressView(value: 1 - fraction).tint(Color.hqTint)
        }
        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let api = router.gatewaySettings?.settingsAPI else { return }
        do {
            state = try await api.rpc("billing.state")
            error = nil
        } catch {
            AppLog.note("settings", "billing load failed: \(type(of: error))")
            self.error = SettingsErrorText.load(error)
        }
    }
}

// MARK: - Sessions

struct SessionsSettingsView: View {
    let store: GatewayConfigStore
    let router: SettingsRouter
    @State private var days = ""
    @State private var folder = ""
    @FocusState private var focused: Bool

    private var enabled: Bool { store.value("sessions.auto_archive")?.bool ?? false }
    private var storedDays: Int { max(1, store.value("sessions.auto_archive_days")?.int ?? 30) }

    var body: some View {
        List { Group {
            ConfigFailureSection(store: store)
            if store.config == nil {
                if case .failed(let text) = store.phase {
                    LoadFailureSection(title: "Couldn’t Load Settings", text: text) { Task { await store.load(force: true) } }
                } else {
                    LoadingSection()
                }
            } else {
                Section {
                    SwitchRow(title: "Auto-Archive Stale Chats", isOn: Binding(get: { enabled }, set: { on in
                        Haptics.play(.selection)
                        // Sparse: both keys, as the web writes them.
                        store.set("sessions.auto_archive", .bool(on))
                        store.set("sessions.auto_archive_days", .number(Double(storedDays)))
                    }))
                    .accessibilityIdentifier("sessions.auto-archive")
                    if enabled {
                        HStack {
                            Text("Archive After").foregroundStyle(Color.hqLabel)
                            Spacer()
                            TextField("30", text: $days)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                                .focused($focused)
                                .onSubmit(commitDays)
                                .numberPadDone(commitDays)   // [diagnostics] on the field, so only the number pad carries it
                                .accessibilityIdentifier("sessions.auto-archive-days")
                            Text("days").foregroundStyle(Color.hqLabel2)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    }
                } footer: { HQSectionFooter {
                    Text("Automatically archive chats you haven’t touched in a while. Pinned chats are never archived, and nothing is deleted.")
                } }
                if let account = router.services.account {
                    Section {
                        if DeviceWord.isMac {
                            // [mac] Stress test 2026-10-28 #51 (review): the folder typed in place, not a page for one field.
                            DefaultProjectFolderField(router: router, account: account.id, folder: $folder)
                        } else {
                        Button {
                            router.push("Default Project Folder", DefaultProjectFolderPage(router: router, account: account.id) { folder = $0 ?? "" })
                        } label: {
                            HStack {
                                Text("Folder").foregroundStyle(Color.hqLabel)
                                Spacer(minLength: 12)
                                Text(folder.isEmpty ? "Not Set" : folder).foregroundStyle(Color.hqLabel2)
                                    .lineLimit(1).truncationMode(.middle)
                                    .accessibilityIdentifier("sessions.default-folder")
                                SettingsChevron()  // [mac] Stress test 2026-10-28 #51: no › on the Mac
                            }
                            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                        }
                        }
                    } header: { HQSectionLabel {
                        Text("Default Project Folder")
                    } } footer: { HQSectionFooter {
                        Text("New chats start in this folder on \(HostWord.phrase) unless you pick another. Leave it empty to use the folder set in Settings › Workspace › Projects. This choice is saved only in Hermes HQ on this \(DeviceWord.name), not in Hermes.")
                    } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(store.failure?.text)
        .task {
            await store.load()
            days = String(storedDays)
            if let account = router.services.account { folder = DefaultProjectFolder.path(account: account.id) ?? "" }
        }
        .onDisappear {
            commitDays()
            store.flush()
        }
        .accessibilityIdentifier("sessions-settings.list")
    }

    private func commitDays() {
        guard enabled, let value = Int(days.trimmingCharacters(in: .whitespaces)), value >= 1, value != storedDays else {
            if !days.isEmpty, Int(days) == nil || (Int(days) ?? 1) < 1 { days = String(storedDays) }
            return
        }
        store.set("sessions.auto_archive", .bool(true))
        store.set("sessions.auto_archive_days", .number(Double(value)))
    }
}

/// Default Project Folder's page: a typed path, checked on the gateway before it is kept (spec §5, DECISION 5.1).
/// [mac] Stress test 2026-10-28 #51 (review): Settings › Sessions' default project folder typed in place on the Mac
/// (it was a page of its own with one field). Written when Return is pressed or the field is left, after the same check
/// `DefaultProjectFolderPage` makes (the folder exists on the computer running Hermes); emptied, it is cleared.
struct DefaultProjectFolderField: View {
    let router: SettingsRouter
    let account: String
    @Binding var folder: String
    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        MacFormRow(label: "Folder") {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField("Folder", text: $text, prompt: MacField.prompt("/Users/you/Projects/app"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .hqMacFieldBox()
                        .focused($focused)
                        .disabled(checking)
                        .onSubmit { Task { await commit() } }
                        .accessibilityLabel("Default Project Folder")
                        .accessibilityIdentifier("sessions.default-folder")
                    if checking { ProgressView().controlSize(.small) }
                }
                if let problem {
                    Text(problem).font(MacType.footnoteFont).foregroundStyle(Color.hqRed)
                        .accessibilityIdentifier("sessions.default-folder.problem")
                }
            }
        }
        .onAppear { text = folder }
        .onChange(of: folder) { _, now in if !focused { text = now } }
        .onChange(of: focused) { _, now in if !now { Task { await commit() } } }
    }

    private func commit() async {
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != folder, !checking else { return }
        if path.isEmpty {
            DefaultProjectFolder.set(nil, account: account)
            folder = ""
            problem = nil
            return
        }
        checking = true
        problem = nil
        defer { checking = false }
        do {
            guard let api = router.gatewaySettings?.settingsAPI else { throw CancellationError() }
            guard try await api.folderExists(path) else {
                Haptics.play(.error)
                problem = "Couldn’t open the folder."
                return
            }
            DefaultProjectFolder.set(path, account: account)
            folder = path
            Haptics.play(.success)
        } catch {
            AppLog.note("settings", "default folder check failed: \(type(of: error))")
            Haptics.play(.error)
            problem = "Couldn’t update the default folder."
        }
    }
}

struct DefaultProjectFolderPage: View {
    let router: SettingsRouter
    let account: String
    var changed: (String?) -> Void
    @State private var text = ""
    @State private var saved: String?
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List { Group {
            Section {
                TextField("/Users/you/Projects/app", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit { Task { await save() } }
                    .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    .accessibilityIdentifier("sessions.default-folder.field")
                if let problem {
                    Text(problem).font(Font.hq(.footnote)).foregroundStyle(Color.red)
                        .accessibilityIdentifier("sessions.default-folder.problem")
                }
            } footer: { HQSectionFooter {
                Text("New chats start in this folder on \(HostWord.phrase) unless you pick another. Leave it empty to use the folder set in Settings › Workspace › Projects. This choice is saved only in Hermes HQ on this \(DeviceWord.name), not in Hermes.")
            } }
            if saved != nil {
                Section {
                    Button("Clear", role: .destructive) {
                        Haptics.play(.selection)
                        DefaultProjectFolder.set(nil, account: account)
                        saved = nil; text = ""; problem = nil
                        changed(nil)
                    }
                    .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    .accessibilityIdentifier("sessions.default-folder.clear")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if checking {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.return, modifiers: .command)   // ⌘Return saves, as in New Job
                        .disabled(trimmed.isEmpty || trimmed == saved)
                        .accessibilityIdentifier("sessions.default-folder.save")
                }
            }
        }
        .task {
            saved = DefaultProjectFolder.path(account: account, profile: "default")
            text = saved ?? ""
        }
        .accessibilityIdentifier("sessions.default-folder.page")
    }

    private func save() async {
        let path = trimmed
        guard !path.isEmpty, path != saved, !checking else { return }
        checking = true; problem = nil
        defer { checking = false }
        do {
            guard let api = router.gatewaySettings?.settingsAPI else { throw CancellationError() }
            guard try await api.folderExists(path) else {
                Haptics.play(.error)
                problem = "Couldn’t open the folder."
                return
            }
            DefaultProjectFolder.set(path, account: account)
            saved = path
            changed(path)
            Haptics.play(.success)
            router.navigation?.popViewController(animated: true)
        } catch {
            AppLog.note("settings", "default folder check failed: \(type(of: error))")
            Haptics.play(.error)
            problem = "Couldn’t update the default folder"
        }
    }
}
