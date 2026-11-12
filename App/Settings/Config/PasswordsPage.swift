// [passwords-page] More › Passwords (and Settings › Passwords, the same page). Owner 2026-11-11, after asking where
// every password is kept: "that should be on the More page and you click in to it it's super organized and easy".
// One page for every secret, by where it is kept:
//   1. what the bots fill in Hermes's browser (the vault on the gateway), a section per kind: Logins, Cards, Addresses;
//   2. the password managers on the gateway the bots may fill from;
//   3. the keys in Hermes's settings (Provider Keys, Tool Keys: the Settings pages, with how many are set);
//   4. what this iPhone's Keychain holds: the gateway sign-in and the Composio key.
// The vault's model and its add form are in VaultBillingPages.swift.

import SwiftUI
import UIKit

/// How the saved items are laid out: a section per kind, Logins first, each by name.
nonisolated enum PasswordsLayout {
    struct Group: Identifiable, Equatable {
        var id: String   // the kind
        var title: String
        var symbol: String
        var items: [VaultItem]
    }

    private static let order = ["login", "payment", "address"]

    static func title(_ kind: String) -> String {
        switch kind {
        case "login": "Logins"
        case "payment": "Cards"
        case "address": "Addresses"
        default: ConfigText.pretty(kind)
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "login": "key"
        case "payment": "creditcard"
        case "address": "house"
        default: "lock"
        }
    }

    static func groups(_ items: [VaultItem]) -> [Group] {
        let kinds = Dictionary(grouping: items, by: \.kind)
        let known = order.filter { kinds[$0] != nil }
        let others = kinds.keys.filter { !order.contains($0) }.sorted()
        return (known + others).map { kind in
            Group(id: kind, title: title(kind), symbol: symbol(kind),
                  items: (kinds[kind] ?? []).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
        }
    }

    /// A row's trailing words, short enough for one line: who a login signs in as ("ivy@example.com"), else the
    /// site it is filled on ("bank.com").
    static func detail(_ item: VaultItem) -> String? {
        if let who = item.identifier, !who.isEmpty { return who }
        guard let host = item.origin.flatMap({ URL(string: $0)?.host() }), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "3 Set", or "None Set".
    static func setCount(_ vars: [EnvVarInfo]) -> String {
        let count = vars.filter(\.isSet).count
        return count == 0 ? "None Set" : "\(count) Set"
    }
}

/// The page on a navigation stack: More's row and Settings' row both make one.
final class PasswordsPageController: UIHostingController<HQScaledRoot<PasswordsPageView>> {
    let router: SettingsRouter
    private let vault: VaultModel

    init(router: SettingsRouter) {
        self.router = router
        let vault = VaultModel(api: router.gatewaySettings?.settingsAPI, readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false)
        self.vault = vault
        let keys = EnvKeysModel(api: router.gatewaySettings?.settingsAPI, readOnly: router.gatewaySettings?.isReadOnlyGateway ?? false)
        super.init(rootView: HQScaledRoot(PasswordsPageView(router: router, model: vault, keys: keys)))
        title = "Passwords"
        navigationItem.largeTitleDisplayMode = .never
        // The iPhone's one way to add is the + in the bar (as the Passwords app); the Mac has its add row in the list.
        if !DeviceWord.isMac, vault.api != nil {
            let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.add() })
            add.accessibilityLabel = "Add a Login, Card or Address"
            add.accessibilityIdentifier = "vault.add"
            navigationItem.rightBarButtonItem = add
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pushed from More's row, its router learns the stack it is on here (as the gateway card's page).
        if router.navigation == nil { router.navigation = navigationController }
    }

    private func add() { PasswordsPageView.openAdd(vault, router: router) }
}

struct PasswordsPageView: View {
    let router: SettingsRouter
    let model: VaultModel
    let keys: EnvKeysModel
    @State private var unlocking: VaultSource?
    @State private var masterPassword = ""
    /// [mac-audit] The row under the pointer: its delete button shows.
    @State private var hovered: VaultItem.ID?
    /// This device's Composio key, read when the page shows (the last four characters only).
    @State private var composio: (saved: Bool, hint: String) = (false, "")

    static func openAdd(_ model: VaultModel, router: SettingsRouter) {
        router.push("Add to Vault", VaultAddView(model: model) { [weak router] in router?.navigation?.popViewController(animated: true) })
    }

    var body: some View {
        List { Group {
            if let failure = model.failure {
                SaveFailureSection(text: failure, detail: nil, retry: model.lastWrite == nil ? nil : { model.retry() },
                                   dismiss: { model.dismissFailure() })
            }
            if model.api != nil {
                saved
                managers
                gatewayKeys
            }
            onThisDevice
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .saveFailureFeedback(model.failure)
        .task { await model.load() }
        .task { await keys.load() }
        .refreshable { await model.load(); await keys.load() }
        .onAppear { composio = ComposioKeychain().status() }
        .alert("Unlock \(unlocking?.name ?? "")", isPresented: Binding(get: { unlocking != nil }, set: { if !$0 { unlocking = nil; masterPassword = "" } })) {
            SecureField("Master Password", text: $masterPassword)
            Button("Cancel", role: .cancel) { masterPassword = "" }
            Button("Unlock") {
                let source = unlocking, password = masterPassword
                masterPassword = ""
                if let source { Task { _ = await model.unlock(source, password: password) } }
            }
        }
        .accessibilityIdentifier("vault.list")
    }

    // MARK: 1. What the bots fill

    private var savedFooter: String {
        "Your bots fill these in Hermes’s browser without ever seeing them. They’re kept encrypted on \(HostWord.phrase)."
            + (DeviceWord.isMac || model.items.isEmpty ? "" : " Swipe left to delete one.")
    }

    @ViewBuilder private var saved: some View {
        if let error = model.loadError, !model.loaded {
            LoadFailureSection(title: "Couldn’t Load Passwords", text: error) { Task { await model.load() } }
        } else if !model.loaded {
            LoadingSection()
        } else {
            let groups = PasswordsLayout.groups(model.items)
            if groups.isEmpty {
                Section {
                    Text(DeviceWord.isMac ? "Nothing saved yet." : "Nothing saved yet. Tap + to add a login, card or address.")
                        .foregroundStyle(Color.hqLabel2)
                    if DeviceWord.isMac { addRow }
                } header: { HQSectionLabel {
                    Text("Logins, Cards & Addresses")
                } } footer: { HQSectionFooter {
                    Text(savedFooter)
                } }
            }
            ForEach(groups) { group in
                let last = group.id == groups.last?.id
                Section {
                    ForEach(group.items) { item in row(item, symbol: group.symbol) }
                    if DeviceWord.isMac, last { addRow }
                } header: { HQSectionLabel {
                    Text(group.title)
                } } footer: {
                    if last { HQSectionFooter { Text(savedFooter) } }
                }
            }
        }
    }

    /// [mac] Stress test 2026-10-28 round 8: the Mac's one add row (the iPhone's is the + in the bar).
    private var addRow: some View {
        Button { Self.openAdd(model, router: router) } label: { MacAddRowLabel(title: "Add to Vault…") }
            .accessibilityIdentifier("vault.add")
    }

    private func canDelete(_ item: VaultItem) -> Bool { item.backend == nil || item.backend == "local" }

    /// One line: the kind's tile, the name, then who (or where) in grey.
    private func row(_ item: VaultItem, symbol: String) -> some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: item.label, systemImage: symbol)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let detail = PasswordsLayout.detail(item) {
                Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
            }
            // [mac-audit] Owner 2026-11-02 (round-4 #13): the Mac shows a trash button on the row under the pointer only
            // (as Finder's and Mail's hover buttons), beside right-click › Delete; VoiceOver and the keyboard still
            // reach it on every row.
            if DeviceWord.isMac, canDelete(item) {
                Button { confirmRemove(item) } label: {
                    Image(systemName: "trash").foregroundStyle(Color.hqLabel2)
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .opacity(hovered == item.id ? 1 : 0)
                .accessibilityLabel("Delete \(item.label)")
                .accessibilityIdentifier("vault-item.delete.\(item.label)")
            }
        }
        .hqMacFormRowHeight()
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vault-item.\(item.label)")
        .swipeActions {
            if canDelete(item) { Button("Delete") { confirmRemove(item) }.tint(.red) }
        }
        // [mac] A mouse has no swipe: the same Delete on a right-click (and a touch and hold).
        .contextMenu {
            if canDelete(item) { Button("Delete", systemImage: "trash", role: .destructive) { confirmRemove(item) } }
        }
    }

    // MARK: 2. Password managers

    @ViewBuilder private var managers: some View {
        if model.loaded, !model.sources.isEmpty {
            Section {
                ForEach(model.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        // Stress test 2026-10-28 #87 (both): the subtitle says what the switch does and what locked means.
                        SwitchRow(title: source.name, subtitle: VaultSource.subtitle(source),
                                  isOn: Binding(get: { source.enabled }, set: { on in Task { _ = await model.setSource(source, enabled: on) } }),
                                  disabled: !source.installed)
                        if source.enabled, source.installed {
                            Button(source.unlocked ? "Lock" : "Unlock…") {
                                if source.unlocked { Task { if await model.lock(source) { Haptics.play(.success) } } } else { unlocking = source }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .accessibilityIdentifier("vault-source.\(source.id)")
                }
            } header: { HQSectionLabel {
                Text("Password Managers")
            } } footer: { HQSectionFooter {
                Text("Let bots fill logins from a password manager on \(HostWord.phrase). Its master password is sent once to unlock it and never kept.")
            } }
        }
    }

    // MARK: 3. Keys in Hermes's settings

    private var gatewayKeys: some View {
        Section {
            NavRow(title: "Provider Keys", systemImage: "bolt",
                   value: keys.loaded ? PasswordsLayout.setCount(EnvKeys.providerKeys(keys.vars)) : nil) {
                SettingsNavigator.openRoot("providers", router: router)
            }
            .accessibilityIdentifier("passwords.provider-keys")
            NavRow(title: "Tool Keys", systemImage: "wrench",
                   value: keys.loaded ? PasswordsLayout.setCount(EnvKeys.toolKeys(keys.vars) + EnvKeys.otherKeys(keys.vars)) : nil) {
                SettingsNavigator.openRoot("keys", router: router)
            }
            .accessibilityIdentifier("passwords.tool-keys")
        } header: { HQSectionLabel {
            Text("Keys")
        } } footer: { HQSectionFooter {
            Text("Kept in Hermes’s settings on \(HostWord.phrase). Hermes HQ shows them hidden.")
        } }
    }

    // MARK: 4. This device's Keychain

    private var signInValue: String? {
        guard let account = router.services.account else { return nil }
        return account.kind == .nous ? "Nous Account" : account.username
    }

    private var onThisDevice: some View {
        Section {
            if router.services.account != nil {
                NavRow(title: "Gateway Sign-In", systemImage: "person.badge.key", value: signInValue) {
                    router.push(GatewayPageController(services: router.services, router: router))
                }
                .accessibilityIdentifier("passwords.sign-in")
            }
            NavRow(title: "Composio Key", systemImage: "powerplug", value: composio.saved ? "····\(composio.hint)" : "Not Set") {
                router.push(ConnectAppsScreens.makeRoot(services: router.services))
            }
            .accessibilityIdentifier("passwords.composio")
        } header: { HQSectionLabel {
            Text("On This \(DeviceWord.name)")
        } } footer: { HQSectionFooter {
            Text("Kept in this \(DeviceWord.name)’s Keychain. The password you sign in with isn’t kept, only the sign-in it gives back.")
        } }
    }

    private func confirmRemove(_ item: VaultItem) {
        TextPrompt.confirm(title: "Delete “\(item.label)”?", message: "Bots can’t fill it any more. This can’t be undone.",
                           action: "Delete", from: router.presenter) {
            Task {
                if await model.remove(item) { Haptics.play(.success) }
            }
        }
    }
}
