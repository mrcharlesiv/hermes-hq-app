// Settings › Gateway (spec 1x-settings §3.4, §4.3–4.5): the saved gateways (check on the one in use; tap to switch;
// Rename and Remove by swipe, menu or Edit; Add Gateway…), the connection in use, and Sign Out.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class GatewayPageModel {
    var rows: [GatewayAccountRow] = []
    var editing = false
    var failure: String?
    var switching: String?
    /// The row whose removal (its gateway's logout, up to 6 s) is running.
    var removing: String?
    var address = ""
    var accountName = ""
    var host = ""
    /// The gateway ended this phone's session and "Sign in again" was put off: the Connection card offers it.
    var signedOut = false

    @ObservationIgnored let services: any AppServices
    @ObservationIgnored let router: SettingsRouter
    @ObservationIgnored private var token: UUID?
    /// Verify round 3: where the Sign Out row is on screen (window coordinates), for its confirmation's arrow.
    @ObservationIgnored var signOutFrame: CGRect = .zero
    /// The page's title changes with the number of gateways (its controller sets it).
    @ObservationIgnored var onTitleChange: ((String) -> Void)?
    /// Hermes Cloud, once a saved gateway is hosted by Nous: the agent's controls on this page and its rows' state.
    private(set) var cloud: CloudGatewayModel?

    init(services: any AppServices, router: SettingsRouter) {
        self.services = services
        self.router = router
        refresh()
    }

    var gateways: (any GatewayAccounts)? { (services as? SettingsServices)?.gateways }

    func start() {
        guard token == nil else { return }
        token = gateways?.observe { [weak self] in self?.refresh() }
        // [update-flow] Each gateway's Hermes version and whether an update is out (one read per gateway per app run;
        // a gateway that isn't in use through its own saved session).
        for row in rows where row.hasSession { HermesUpdateCenter.shared.refresh(row.account) }
    }

    /// [update-flow] A row's Hermes: its version, an update that's out (and its Update button), or the update running.
    func update(_ row: GatewayAccountRow) -> GatewayRowUpdate? {
        let center = HermesUpdateCenter.shared
        if let run = center.run(row.account.id) {
            return GatewayRowUpdate(version: nil, available: nil, run: run, update: nil, from: router.presenter)
        }
        // A Nous agent updates through Nous (its image), as its own page does, never through Hermes' own update route.
        let agent = cloudAgent(row)
        if let agent, let run = center.run("cloud:" + agent.id) {
            return GatewayRowUpdate(version: nil, available: nil, run: run, update: nil, from: router.presenter)
        }
        let nous = CloudGatewayFlow.isCloud(row.account.baseURL)
        let version = center.versions[row.account.id]
        let check = center.checks[row.account.id]
        let available = check?.updateAvailable == true
            ? (check?.sourceVersion ?? check?.rollbackTo).map { "\(HermesUpdateEnd.normalized($0)) available" } ?? "Update available" : nil
        guard version != nil || available != nil else { return nil }
        let readOnly = row.isCurrent && ((services as? AppModel)?.readOnlyGateway ?? false)
        return GatewayRowUpdate(version: version.map { "Hermes \(HermesUpdateEnd.normalized($0))" }, available: available, run: nil,
                                update: available != nil && row.hasSession && !readOnly && (!nous || agent != nil)
                                    ? { [weak self] in self?.updateHermes(row) } : nil)
    }

    func updateHermes(_ row: GatewayAccountRow) {
        if CloudGatewayFlow.isCloud(row.account.baseURL) {
            // Nous agent: the Nous reinstall (the agent page's Update); one Hermes Cloud hasn't listed gets no Update.
            guard let cloud, let agent = cloudAgent(row) else { return }
            cloud.askUpdate(agent)
            return
        }
        HermesUpdateCenter.shared.update(row.account, from: router.presenter)
    }

    /// The Nous agent a Nous-hosted row is, once Hermes Cloud has listed it.
    private func cloudAgent(_ row: GatewayAccountRow) -> CloudAgent? {
        guard CloudGatewayFlow.isCloud(row.account.baseURL) else { return nil }
        return cloud?.agent(atHost: row.account.baseURL)
    }

    func stop() {
        if let token { gateways?.stopObserving(token) }
        token = nil
    }

    isolated deinit { stop() }

    func refresh() {
        rows = gateways?.accounts ?? services.account.map {
            let name = GatewayNaming.accountName($0)
            let row = GatewayNaming.row(url: $0.baseURL, label: nil, accountName: name, hasSession: true)
            return [GatewayAccountRow(id: $0.id, account: $0, title: row.title, subtitle: row.subtitle, label: nil,
                                      hostAndPort: GatewayNaming.host($0.baseURL, port: true), accountName: name,
                                      isCurrent: true, hasSession: true, news: 0)]
        } ?? []
        switching = gateways?.switchingTo
        if let account = services.account {
            address = account.baseURL.absoluteString
            accountName = GatewayNaming.accountName(account)
            host = GatewayNaming.host(account.baseURL, port: true)
        }
        if rows.count < 2 { editing = false }
        if cloud == nil, let settings = services as? SettingsServices, rows.contains(where: { CloudGatewayFlow.isCloud($0.account.baseURL) }) {
            cloud = CloudGatewayFlow.settingsModel(settings: settings, services: services, router: router)
            #if DEBUG
            if let state = UserDefaults.standard.string(forKey: "HQDebugCloudPanel"), let url = current?.account.baseURL {
                cloud?.debugPanel(state, host: url, other: rows.first { !$0.isCurrent }?.account.baseURL)
            }
            #endif
            cloud?.appear()
        }
        signedOut = (services as? AppModel)?.offlineHub.sessionEnded ?? false
        onTitleChange?(pageTitle)
    }

    /// "Gateways" once there are several (the title menu's Manage Gateways… and the list's own header say so too).
    var pageTitle: String { rows.count > 1 ? "Gateways" : "Gateway" }

    var footer: String {
        if let failure { return failure }
        return rows.count > 1
            // Push comes from one gateway (MEM gateway-switcher): the footer says so (UX study #268).
            ? "Each gateway keeps its own chats, drafts and sign-in on this \(DeviceWord.name). Switching doesn’t sign you out. "
                + "Alerts come only from the gateway in use."
            : "Add another gateway to switch between them here. Each keeps its own chats, drafts and sign-in."
    }

    /// The address and account are the rows just above, so the footer says only what they don't. UX study #24: it ties
    /// the Address row back to the one typed at sign-in, and names the computer as HostWord does.
    /// [mac] Stress test 2026-10-28 #60: the host is named once, as HostWord does, and not set against "your Mac" (which
    /// is often the same computer, so the sentence read as two).
    var connectionFooter: String {
        "The Address is the one you signed in with: where Hermes HQ finds \(HostWord.phrase). "
            + "You stay signed in through \(DeviceWord.system) Keychain (never your password), and it renews itself."
    }

    /// The gateway in use, for the Connection card's Name row (Rename without a swipe or Edit).
    var current: GatewayAccountRow? { gateways == nil ? nil : rows.first(where: \.isCurrent) }

    // MARK: Actions

    func tap(_ row: GatewayAccountRow) {
        guard !row.isCurrent, switching == nil, removing != row.id, let gateways else { return }
        GatewaySwitchGuard.confirm(switchingTo: row.title, from: router.presenter) { [weak self] in
            self?.switchTo(row, gateways)
        }
    }

    private func switchTo(_ row: GatewayAccountRow, _ gateways: any GatewayAccounts) {
        guard switching == nil, removing != row.id else { return }
        failure = nil
        Task {
            do {
                try await gateways.switchTo(row.id)
                refresh()
            } catch GatewaySwitchError.needsSignIn(let account) {
                AddGatewayFlow.present(from: router.presenter, services: services, prefill: account)
            } catch is AccountStorageError {                // [offline] §3.4: the storage sentence
                Haptics.play(.error)
                failure = StartupProblems.storage
                refresh()
            } catch {
                Haptics.play(.error)
                failure = GatewaySwitchError.reason(switchingTo: row.title)
                refresh()
            }
        }
    }

    func rename(_ row: GatewayAccountRow) {
        TextPrompt.present(title: "Rename Gateway",
                           message: "A name for \(row.hostAndPort) on this \(DeviceWord.name). Leave it blank to use its address.",
                           text: row.label ?? "", placeholder: row.title, action: "Save", maxLength: 60, allowBlank: true,
                           // A gateway's name is often a host-style label ("studio", "my-mac.tail"): typed as is.
                           identifier: "gateway.rename.field", autocapitalization: .none, autocorrection: .no,
                           from: router.presenter) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (row.label ?? "") else { return }
            do {
                try self.gateways?.rename(row.id, trimmed.isEmpty ? nil : trimmed)
                Haptics.play(.success)
                self.failure = nil
            } catch {
                Haptics.play(.error)
                self.failure = "Couldn’t rename \(row.title). Try again."
            }
            self.refresh()
        }
    }

    func remove(_ row: GatewayAccountRow) {
        guard !row.isCurrent else { return }
        TextPrompt.confirm(title: "Remove \(row.title)?",
                           message: SignOutWords.remove(row),
                           action: "Remove Gateway", from: router.presenter) { [weak self] in
            guard let self, self.removing == nil else { return }
            self.removing = row.id
            self.failure = nil
            Task {
                do {
                    try await self.gateways?.remove(row.id)
                    Haptics.play(.success)
                    self.failure = nil
                } catch {
                    Haptics.play(.error)
                    self.failure = "Couldn’t remove \(row.title). Try again."
                }
                self.removing = nil
                self.refresh()
            }
        }
    }

    func addGateway() {
        // A sign-in that succeeds switches to the new gateway: Talk or a memo take would end with it.
        GatewaySwitchGuard.confirm(switchingTo: nil, from: router.presenter) { [weak self] in
            guard let self else { return }
            AddGatewayFlow.present(from: self.router.presenter, services: self.services)
        }
    }

    /// A Hermes that Nous hosts, made or picked from Hermes Cloud (App/Gateways/CloudGatewayFlow.swift).
    func addCloudGateway() {
        GatewaySwitchGuard.confirm(switchingTo: nil, from: router.presenter) { [weak self] in
            guard let self else { return }
            CloudGatewayFlow.present(from: self.router.presenter, services: self.services)
        }
    }

    /// The session ended and "Sign in again" was put off (UX study #121): the notice's own action, from here.
    /// The current gateway's agent when it's hosted by Nous and Hermes Cloud has found it.
    var currentCloudURL: URL? {
        guard let url = current?.account.baseURL, CloudGatewayFlow.isCloud(url) else { return nil }
        return url
    }

    /// Nous's word on a hosted gateway's row ("Running · Standard · $0.56 a day"), once Hermes Cloud has listed it.
    func cloudLine(_ row: GatewayAccountRow) -> String? {
        guard CloudGatewayFlow.isCloud(row.account.baseURL), let agent = cloud?.agent(atHost: row.account.baseURL) else { return nil }
        if let busy = cloud?.busy[agent.id] { return busy.words }
        return CloudCopy.gatewayRowLine(agent)
    }

    /// Another Nous-hosted gateway's controls, without switching to it (its ⓘ, as Wi-Fi's).
    func manageCloud(_ row: GatewayAccountRow) {
        guard let cloud else { return }
        if let agent = cloud.agent(atHost: row.account.baseURL) { cloud.open(agent) }
        else { CloudGatewayFlow.present(from: router.presenter, services: services, agent: row.account.baseURL) }
    }

    /// Pull to refresh: Nous's list again.
    func refreshCloud() async {
        await cloud?.refresh()
    }

    func signInAgain() {
        guard let hub = (services as? AppModel)?.offlineHub else { return }
        // A sheet goes first: the app's root changes to the sign-in form.
        if let sheet = router.presenter?.navigationController?.presentingViewController {
            sheet.dismiss(animated: true) { hub.signInAgain() }
        } else {
            hub.signInAgain()
        }
    }

    func signOut() {
        let services = self.services
        let presenter = router.presenter
        // The given name, as everywhere else (#75); the address when the page has no rows.
        let name = current?.title ?? host
        let next = rows.first { !$0.isCurrent }?.title
        let words = SignOutWords.signOut(accountId: services.account?.id, name: name, next: next)
        let alert = UIAlertController(title: words.title, message: words.message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak presenter] _ in
            // A sheet goes first: the app's root changes after a sign-out.
            if let sheet = presenter?.navigationController?.presentingViewController {
                sheet.dismiss(animated: true) { services.signOut() }
            } else {
                services.signOut()
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController, let view = presenter?.view {
            // From the Sign Out row itself (verify round 3: a fixed point near the view's bottom landed in the tab bar
            // on More's stack, and in empty space in the Bots bar's sheet).
            popover.sourceView = view
            let row = signOutFrame.isEmpty ? .null : view.convert(signOutFrame, from: nil)
            popover.sourceRect = row.isNull || !view.bounds.intersects(row)
                ? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0) : row
        }
        FailureAlert.topmost(presenter)?.present(alert, animated: true)
    }
}

final class GatewayPageController: UIHostingController<HQScaledRoot<GatewayPageView>> {
    let model: GatewayPageModel

    init(services: any AppServices, router: SettingsRouter) {
        let model = GatewayPageModel(services: services, router: router)
        self.model = model
        super.init(rootView: HQScaledRoot(GatewayPageView(model: model)))
        title = model.pageTitle
        navigationItem.largeTitleDisplayMode = .never
        model.onTitleChange = { [weak self] title in
            if self?.title != title { self?.title = title }
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pushed from More's gateway card, its router learns the stack it is on here.
        if model.router.navigation == nil { model.router.navigation = navigationController }
        model.refresh()
        model.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController == nil || isMovingFromParent { model.stop() }
    }
}

struct GatewayPageView: View {
    @Bindable var model: GatewayPageModel

    var body: some View {
        ScrollViewReader { proxy in
        List { Group {
            // Hosted by Nous: the agent itself comes first (its power and settings), then the gateway's own sections.
            if let url = model.currentCloudURL, let cloud = model.cloud {
                CloudGatewayPanel(model: cloud, host: url)
            }
            Section {
                ForEach(model.rows) { row in
                    GatewayRowView(row: row, switching: model.switching == row.id, removing: model.removing == row.id,
                                   editing: model.editing, rename: { model.rename(row) }, remove: { model.remove(row) },
                                   cloudLine: model.cloudLine(row), update: model.update(row),
                                   manage: CloudGatewayFlow.isCloud(row.account.baseURL) && !row.isCurrent ? { model.manageCloud(row) } : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { if !model.editing { model.tap(row) } }
                        .accessibilityAddTraits(row.isCurrent ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("gateway-row-\(row.title)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !row.isCurrent {
                                // Red, but not the destructive role: that role animates the row out at once, before the
                                // confirm, and the list's own update then crashed (row counts disagreed).
                                Button("Remove") { model.remove(row) }.tint(.red)
                            }
                            Button("Rename") { model.rename(row) }.tint(.gray)
                        }
                        .contextMenu {
                            if CloudGatewayFlow.isCloud(row.account.baseURL), !row.isCurrent {
                                Button(CloudCopy.manageAgent, systemImage: "cloud") { model.manageCloud(row) }
                            }
                            Button("Rename…", systemImage: "pencil") { model.rename(row) }
                            if !row.isCurrent {
                                Button("Remove…", systemImage: "minus.circle", role: .destructive) { model.remove(row) }
                            }
                        }
                }
                Button { model.addGateway() } label: {
                    if DeviceWord.isMac { Text("Add Gateway…") } else { Label("Add Gateway…", systemImage: "plus") }
                }
                .accessibilityIdentifier("gateway.add")
                .hqMacPushButton(leading: true)   // [mac] Stress test 2026-10-28 #51: a push button under the list's rows, at its leading edge
                .hqMacSettingsControl()   // [mac] Stress test 2026-10-28 round 10: 59 pt like the rows (it was 62)
                Button { model.addCloudGateway() } label: {
                    if DeviceWord.isMac { Text(CloudCopy.menuTitle) } else { Label(CloudCopy.menuTitle, systemImage: "cloud") }
                }
                .accessibilityIdentifier("gateway.add-cloud")
                .hqMacPushButton(leading: true)
                .hqMacSettingsControl()
            } header: { HQSectionLabel {
                HStack {
                    Text("Gateways")
                    Spacer()
                    if model.rows.count >= 2 {
                        Button(model.editing ? "Done" : "Edit") {
                            HQMotion.withAnimation { model.editing.toggle() }
                        }
                        .font(Font.hq(.subheadline).weight(model.editing ? .semibold : .regular))
                        .textCase(nil)
                        .accessibilityIdentifier("gateway.edit")
                    }
                }
            } } footer: { HQSectionFooter {
                Text(model.footer)
                    .foregroundStyle(model.failure == nil ? Color.hqLabel2 : Color.hqRed)
            } }

            Section {
                if model.signedOut {
                    Button("Sign In Again") { model.signInAgain() }
                        .accessibilityIdentifier("gateway.sign-in-again")
                }
                // Hosted by Nous and found there: its name is the agent's (the Agent section renames it on Nous).
                if let current = model.current, model.currentCloudURL.flatMap({ model.cloud?.agent(atHost: $0) }) == nil {
                    Button { model.rename(current) } label: {
                        // A name given is a value (secondary, as Account below); none yet is an invitation (tint).
                        LabeledContent {
                            HStack(spacing: 6) {
                                // [mac] Stress test 2026-10-28 #85: on the Mac a name given is grey like the others and has
                                // no chevron (Rename asks in a prompt; it doesn't push a page). Mac polish #97: none yet
                                // is tinted there too, or "Add Name…" read as a value you can't change.
                                Text(current.label ?? "Add Name…")
                                    .foregroundStyle(current.label == nil ? Color.hqTintText : Color.hqLabel2)
                                if !DeviceWord.isMac {
                                    Image(systemName: "chevron.forward")
                                        .font(Font.hq(.footnote).weight(.semibold))
                                        .foregroundStyle(Color.hqLabel3)
                                        .accessibilityHidden(true)
                                }
                            }
                        } label: {
                            Text("Name").foregroundStyle(Color.hqLabel)
                        }
                    }
                    .accessibilityIdentifier("gateway.name")
                    .accessibilityLabel("Name")
                    .accessibilityValue(current.label ?? "None")
                    .accessibilityHint("Renames this gateway on this \(DeviceWord.name)")
                }
                Group {
                    if DeviceWord.isMac {
                        // [mac] Stress test 2026-10-28 #85: the address is a value on the right, as Name, Account and
                        // Saved Sign-In are (it put its value under a grey label). It still breaks between its parts.
                        LabeledContent {
                            Text(SettingsRootModel.wrappable(model.address))
                                .foregroundStyle(Color.hqLabel2)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(model.address)
                        } label: {
                            Text("Address").foregroundStyle(Color.hqLabel)
                        }
                    } else {
                        // [gateway-rows] Owner 2026-11-10 (design pick 25): an address that fits is a value on the
                        // right of its row, as Name, Account and Saved Sign-In are; a longer one keeps the label over
                        // it, breaking only between its parts.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text("Address").foregroundStyle(Color.hqLabel).fixedSize()
                                Spacer(minLength: 12)
                                Text(model.address).foregroundStyle(Color.hqLabel2).lineLimit(1).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Address").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                                // Breaks only between the address's parts; VoiceOver and Copy get the plain address.
                                Text(SettingsRootModel.wrappable(model.address))
                                    .font(Font.hq(.body))
                                    .foregroundStyle(Color.hqLabel)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(model.address)
                            }
                            .padding(.vertical, 6)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Address")
                        .accessibilityValue(model.address)
                    }
                }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.address }
                }
                // Stress test 2026-10-28 #85 (both): every value in one colour (the system's secondary grey differed
                // from Name's).
                LabeledContent { Text(model.accountName).foregroundStyle(Color.hqLabel2) } label: { Text("Account").foregroundStyle(Color.hqLabel) }
                LabeledContent {
                    Text(model.rows.first(where: \.isCurrent)?.hasSession == false ? "None" : "\(DeviceWord.system) Keychain").foregroundStyle(Color.hqLabel2)
                } label: { Text("Saved Sign-In").foregroundStyle(Color.hqLabel) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("gateway.keychain")
            } header: { HQSectionLabel {
                Text("Connection")
            } } footer: { HQSectionFooter {
                Text(model.connectionFooter)
            } }

            // Where to restart or update this gateway: Status & Maintenance, one tap from its own page (UX study #189).
            // [status-page] The row says the page's own name, as More does (owner 2026-11-03: one page, one name).
            if let open = SettingsHooks.commandCenter?() {
                Section {
                    // [mac] Stress test 2026-10-28 #85: the page's only icon, alone among plain rows; the Mac drops it.
                    NavRow(title: CommandCenterNames.page, systemImage: DeviceWord.isMac ? nil : "gauge.with.dots.needle.67percent") {
                        let page = open()
                        page.navigationItem.largeTitleDisplayMode = .never
                        model.router.push(page)
                    }
                    .accessibilityIdentifier("gateway.command-center")
                } footer: { HQSectionFooter {
                    Text("The Hermes version, Restart Gateway, Update Hermes, Recent Logs and Run Doctor.")
                } }
            }

            if let url = model.currentCloudURL, let cloud = model.cloud {
                CloudGatewayDeleteSection(model: cloud, host: url)
            }

            Section {
                Button("Sign Out", role: .destructive) { model.signOut() }
                    .accessibilityIdentifier("gateway.sign-out")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.signOutFrame = $0 }
                    .hqMacFormButton(destructive: true)   // [mac] Stress test 2026-10-28 #51: a red push button under the form, not alone in a card
            }
            .id("gateway.sign-out")
        }.hqMacSettingsRowInsets() }
        .refreshable { await model.refreshCloud() }
        #if DEBUG
        .task {
            // Screenshots: `-HQDebugGatewaysScroll gateways|bottom` (App/Debug/DebugHooks.swift).
            guard let target = UserDefaults.standard.string(forKey: "HQDebugGatewaysScroll") else { return }
            try? await Task.sleep(for: .seconds(4))       // after the Hermes Cloud panel has drawn above
            if let first = model.rows.first?.id { proxy.scrollTo(first, anchor: .center) }
            guard target == "bottom" else { return }
            try? await Task.sleep(for: .seconds(1))     // Sign Out is drawn once the list is near it
            proxy.scrollTo("gateway.sign-out", anchor: .bottom)
        }
        #endif
        }
        .hqMacForm(settings: true)       // [mac] Stress test 2026-10-28 #8: the readable width (Name and its value ~1000 pt apart)
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("gateway.list")
    }
}

struct GatewayRowView: View {
    let row: GatewayAccountRow
    let switching: Bool
    let removing: Bool
    let editing: Bool
    let rename: () -> Void
    let remove: () -> Void
    /// Hosted by Nous: its state and price a day, in place of the usual subtitle.
    var cloudLine: String? = nil
    /// [update-flow] Its Hermes version and update.
    var update: GatewayRowUpdate? = nil
    /// Hosted by Nous and not in use: ⓘ opens its controls without switching.
    var manage: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the check (or the Edit buttons) goes under the text, so the address keeps the width.
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            // [mac] Stress test 2026-10-31: the Mac's option list, a radio leading the row as on every other page (#51);
            // the ✓ sat at the far end, about 600 pt from the gateway it marked.
            HStack(alignment: .firstTextBaseline, spacing: DeviceWord.isMac ? MacForm.radioGap : 0) {
            HQRadioMark(selected: row.isCurrent)
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsRootModel.wrappable(row.title))
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(row.title)
                let subtitle = switching ? "Switching…" : removing ? "Removing…" : cloudLine ?? row.subtitle
                if !subtitle.isEmpty {
                    Text(SettingsRootModel.wrappable(subtitle))
                        // [mac] Stress test 2026-10-28 round 10: the subtitle size of every other Settings row (it read as
                        // body size beside them).
                        .font(DeviceWord.isMac ? MacType.footnoteFont : Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(subtitle)
                }
                if let update, !switching, !removing { updateLine(update) }
            }
            }
            if !large { Spacer(minLength: 16) }
            if removing {
                ProgressView()
            } else if editing {
                Button("Rename", action: rename).buttonStyle(.borderless)
                if !row.isCurrent {
                    Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless)
                }
            } else if switching {
                ProgressView()
            } else if row.isCurrent {
                if !DeviceWord.isMac {
                    Image(systemName: "checkmark")
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(Color.hqTint)
                        .accessibilityHidden(true)
                }
            } else if let news = GatewayNews.newsLabel(row.news) {
                Text(news).font(Font.hq(.subheadline)).foregroundStyle(Color.hqTintText)
            }
            if let action = update?.update, !editing, !removing, !switching {
                // [update-flow] Update Hermes on this gateway, in use or not: the sheet names it.
                Button("Update", action: action)
                    .hqMacBordered()   // [mac-ui-issues] the Mac's push button, as Add Gateway… under it (was a tinted pill)
                    .controlSize(.small)
                    .accessibilityLabel("Update Hermes on \(row.title)")
                    .accessibilityIdentifier("gateway-row-update-\(row.title)")
            }
            if let manage, !editing, !removing {
                Button(action: manage) {
                    Image(systemName: "info.circle").font(Font.hq(.title3)).foregroundStyle(Color.hqTint)
                        .contentShape(Rectangle().inset(by: -10))   // [ui-sizing] a 44 pt touch (was ~22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(CloudCopy.manageAgent)
                .accessibilityIdentifier("gateway-row-manage-\(row.title)")
            }
        }
        .hqRowPadding(6)   // [mac] Stress test 2026-10-28 round 10: none on the Mac, so the row is its lines and the list's room (89 pt)
        .accessibilityElement(children: editing || manage != nil || update?.update != nil || update?.run != nil ? .contain : .combine)
    }

    private func versionText(_ update: GatewayRowUpdate) -> Text {
        let version = Text(update.version ?? "").foregroundStyle(Color.hqLabel2)
        guard let available = update.available else { return version }
        let tail = Text(available).foregroundStyle(Color.hqTintText)
        return update.version == nil ? tail : version + Text(" · ").foregroundStyle(Color.hqLabel2) + tail
    }

    /// [update-flow] "Hermes 0.22.5 · 0.23.0 available", or "Updating Studio…" with the step under way (a tap: the sheet).
    @ViewBuilder private func updateLine(_ update: GatewayRowUpdate) -> some View {
        let font = DeviceWord.isMac ? MacType.footnoteFont : Font.hq(.footnote)
        if let run = update.run {
            Button { run.show(from: update.from) } label: {
                HStack(spacing: 6) {
                    if run.isRunning { ProgressView().controlSize(.mini) }
                    Text(run.isRunning ? (run.rowStatus.map { "\(run.rowTitle) \($0)" } ?? run.rowTitle) : run.headline)
                        .font(font)
                        .foregroundStyle(Color.hqTintText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Shows the update")
            .accessibilityIdentifier("gateway-row-updating-\(row.title)")
        } else {
            // One Text, so a narrow row wraps it as a sentence ("Update available" stood in its own two-line column).
            versionText(update)
                .font(font)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gateway-row-version-\(row.title)")
        }
    }
}

/// [update-flow] What a gateway row shows about its Hermes.
struct GatewayRowUpdate {
    var version: String?
    var available: String?
    var run: HermesUpdate?
    var update: (() -> Void)?
    /// [mac] Where the run's sheet goes: this page, so the Settings window's own, not the main window behind it (Mac
    /// polish #36).
    weak var from: UIViewController?
}
