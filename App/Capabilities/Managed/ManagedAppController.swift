// One managed app (the desktop's hosted connector dialog): its state and the next step, the sign-in being followed,
// "Hermes can use …" (the member rule), the account with Disconnect, and the tool list with a switch per tool
// (the member's tool rule, saved against the rules' revision; a conflict says what changed and keeps the edits).

import SwiftUI
import UIKit

@MainActor @Observable
final class ManagedAppPage {
    let parent: CapabilitiesModel
    let slug: String
    let profile: String
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored var lockChanged: (() -> Void)?

    enum ToolsState: Equatable { case idle, reading, loaded, signedOut, gone, unavailable(String) }
    var toolsState = ToolsState.idle
    var tools: [ConnectorTool] = []
    var stale = false
    var savedOff: Set<String> = []
    var draftOff: Set<String> = []
    var saving = false
    var showDeprecated = false
    var search = ""
    /// The other side's list after a conflict, until the person picks.
    var theirs: Set<String>?
    @ObservationIgnored private var readRevision = -1

    init(parent: CapabilitiesModel, slug: String) {
        self.parent = parent
        self.slug = slug
        profile = parent.profile
    }

    var managed: ManagedAppsModel? { parent.profile == profile ? parent.managed : nil }
    var app: ManagedApp? { managed?.app(slug) }
    var name: String { app?.name ?? ManagedWire.title(slug) }
    var dirty: Bool { draftOff != savedOff }
    var orgLocked: Set<String> { managed?.policy.orgLockedTools(slug, tools: tools) ?? [] }
    /// The switches act: an account, the app on for this person, and rules that can be written.
    var editable: Bool {
        guard let managed, let app else { return false }
        return app.ruleable && app.state != .off && managed.rulesWritable
    }

    var shownTools: [ConnectorTool] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return tools.filter { showDeprecated || !$0.deprecated }.filter {
            q.isEmpty || [$0.name, $0.slug, $0.description].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
    var deprecatedCount: Int { tools.filter(\.deprecated).count }
    var draftSummary: String {
        ManagedToolWords.draft(off: draftOff.subtracting(savedOff).count, backOn: savedOff.subtracting(draftOff).count)
    }

    func appear() {
        managed?.presenter = presenter
        managed?.load()   // [perf] a reconnect skipped while hidden reads now (a no-op when read under 30 s ago)
        if let managed, readRevision != managed.revision || toolsState == .idle { Task { await readTools() } }
    }

    func readTools(refresh: Bool = false) async {
        guard let managed else { return }
        readRevision = managed.revision
        if tools.isEmpty { toolsState = .reading }
        let start = ContinuousClock.now
        do {
            let result = try await managed.api.tools(slug, refresh: refresh, profile: profile)
            tools = result.tools
            stale = result.stale
            toolsState = .loaded
            applyRules()
            AppLog.trace("connect", "managed app \(slug) tools loaded in \(AppLog.ms(since: start)) ms, \(result.tools.count) tool(s), stale=\(result.stale)")
        } catch {
            let failure = ConnectorFailure(error)
            if refresh, !tools.isEmpty {
                AppLog.note("connect", "managed app \(slug) tools refresh failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                FailureAlert.present(title: "Couldn’t Refresh", reason: "The tool list was not refreshed. \(failure.words())", from: presenter, whole: true)
                return
            }
            switch failure.reason {
            case .needsNousAuth: toolsState = .signedOut
            case .connectorNotFound: toolsState = app?.connected == true ? .unavailable(failure.words()) : .gone
            default: toolsState = .unavailable(failure.words(fallback: "Tool list unavailable."))
            }
            AppLog.note("connect", "managed app \(slug) tools load failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
        }
    }

    /// The rules changed under the page (a save, a reload): the saved set follows; a clean draft follows too.
    func applyRules() {
        let off = Set(managed?.policy.memberDisabledTools(slug) ?? [])
        let wasDirty = dirty
        savedOff = off
        if !wasDirty { draftOff = off }
    }

    func setTool(_ tool: String, on: Bool) {
        Haptics.play(.selection)
        if on { draftOff.remove(tool) } else { draftOff.insert(tool) }
        lockChanged?()
    }

    /// The switchable tools (not deprecated, not locked by the organisation).
    private var switchable: [String] { tools.filter { !$0.deprecated && !orgLocked.contains($0.slug) }.map(\.slug) }

    func setAll(_ on: Bool) {
        Haptics.play(.selection)
        let movable = Set(switchable)
        draftOff = on ? draftOff.subtracting(movable) : draftOff.union(movable)
        lockChanged?()
    }

    /// "Read Only" / "Turn Off Destructive" / "Everything On" (`QUICK_ACTIONS`).
    func quick(offFacets: Set<String>) {
        Haptics.play(.selection)
        var next = draftOff
        for tool in tools where !tool.deprecated && !orgLocked.contains(tool.slug) {
            if offFacets.contains(tool.facet) { next.insert(tool.slug) } else { next.remove(tool.slug) }
        }
        draftOff = next
        lockChanged?()
    }

    func discard() { draftOff = savedOff; theirs = nil; lockChanged?() }

    func save(over revision: String? = nil) {
        guard let managed, dirty || revision != nil, !saving, editable else { return }
        guard let expected = revision ?? managed.policy.memberRevision else {
            FailureAlert.present(title: "Couldn’t Save", reason: "Rules cannot be changed right now.", from: presenter)
            return
        }
        saving = true
        lockChanged?()
        let disabled = tools.map(\.slug).filter(draftOff.contains) + draftOff.filter { slug in !tools.contains { $0.slug == slug } }.sorted()
        let start = ContinuousClock.now
        Task {
            defer { saving = false; lockChanged?() }
            do {
                try await managed.api.setDisabledTools(slug, disabled: disabled, revision: expected, profile: profile)
                Haptics.play(.success)
                theirs = nil
                await managed.reloadPolicy()
                savedOff = Set(managed.policy.memberDisabledTools(slug))
                draftOff = savedOff
                managed.revision += 1
                readRevision = managed.revision
                AppLog.trace("connect", "managed app \(slug) tool rules saved in \(AppLog.ms(since: start)) ms, \(disabled.count) off")
            } catch {
                let failure = ConnectorFailure(error)
                guard failure.reason == .policyConflict else {
                    AppLog.note("connect", "managed app \(slug) tool rules save failed after \(AppLog.ms(since: start)) ms: \(failure.reason?.rawValue ?? "unknown")")
                    FailureAlert.present(title: "Couldn’t Save", reason: "Those tool rules were not saved. \(failure.words())", detail: failure.message,
                                         from: presenter, whole: true)
                    return
                }
                await managed.reloadPolicy()
                let other = Set(managed.policy.memberDisabledTools(slug))
                theirs = other
                savedOff = other
                AppLog.trace("connect", "managed app \(slug) tool rules save hit a policy conflict after \(AppLog.ms(since: start)) ms, asking which version to keep")
                presentConflict(other)
            }
        }
    }

    private func presentConflict(_ other: Set<String>) {
        let mine = draftOff
        let theyOff = other.subtracting(mine).count, theyOn = mine.subtracting(other).count
        let alert = UIAlertController(title: "Someone changed this rule while you were editing.",
                                      message: ManagedToolWords.conflict(theyOff: theyOff, theyOn: theyOn), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Reload Their Version", style: .default) { [weak self] _ in self?.discard() })
        alert.addAction(UIAlertAction(title: "Save Over Their Version", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.save(over: self.managed?.policy.memberRevision)
        })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        FailureAlert.topmost(presenter)?.present(alert, animated: true)
    }
}

// MARK: - Page

final class ManagedAppController: UIHostingController<HQScaledRoot<ManagedAppView>> {
    let page: ManagedAppPage

    init(model: CapabilitiesModel, slug: String, router: SettingsRouter) {
        page = ManagedAppPage(parent: model, slug: slug)
        super.init(rootView: HQScaledRoot(ManagedAppView(page: page, router: router)))
        title = page.name
        navigationItem.largeTitleDisplayMode = .never
        page.presenter = self
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated { done(self?.menuItems() ?? []) }
        }])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "managed.app.more"
        navigationItem.rightBarButtonItem = item
        navigationItem.backAction = UIAction { [weak self] _ in self?.leave() }
        page.lockChanged = { [weak self] in self?.updateLock() }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func menuItems() -> [UIMenuElement] {
        let page = self.page
        var items: [UIMenuElement] = [UIAction(title: "Refresh Tools", image: UIImage(systemName: "arrow.clockwise")) { _ in
            Task { await page.readTools(refresh: true) }
        }]
        if let app = page.app, let managed = page.managed, !managed.readOnly {
            // [accounts] With more than one account, each account's row carries its own Reconnect and Remove.
            if app.connected, !(managed.accountNames && app.accounts.count > 1) {
                items.append(UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in managed.connect(page.slug, reconnect: true) })
                items.append(UIAction(title: "Disconnect", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDisconnect()
                })
            }
        }
        return items
    }

    func confirmDisconnect() {
        guard let managed = page.managed else { return }
        let slug = page.slug
        TextPrompt.confirm(title: "Disconnect \(page.name)?", message: "Hermes stops acting as this account. You can connect again at any time.",
                           action: "Disconnect", from: self) { managed.disconnect(slug) }
    }

    // MARK: Named accounts

    /// Rename (`AliasEditor` for one account): checked here first, then by Hermes; a refusal asks again with its words.
    func rename(_ account: ConnectorAccountRow, draft: String? = nil, problem: String? = nil) {
        guard let managed = page.managed else { return }
        let siblings = (page.app?.accounts ?? []) + (page.app?.retired ?? [])
        TextPrompt.present(title: "Rename \(account.name)", message: problem ?? AccountWords.aliasHint, text: draft ?? account.alias ?? "",
                           placeholder: "Account name", action: "Save", maxLength: 32, requireChange: draft == nil,
                           identifier: "managed-account-name", autocapitalization: .none, autocorrection: .no, from: self) { [weak self] raw in
            let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let self, alias != (account.alias ?? "") else { return }
            if let local = ConnectorAccountRow.aliasProblem(alias, among: siblings, renaming: account.connectionId) {
                self.askAgain { self.rename(account, draft: alias, problem: local) }
                return
            }
            Task {
                if let refused = await managed.rename(account, to: alias) { self.askAgain { self.rename(account, draft: alias, problem: refused) } }
            }
        }
    }

    /// "Add Another Account": a name for it, then the usual sign-in.
    func addAccount(draft: String? = nil, problem: String? = nil) {
        guard let managed = page.managed, let app = page.app else { return }
        TextPrompt.present(title: "Add Another \(app.name) Account", message: problem ?? AccountWords.aliasHint, text: draft ?? "",
                           placeholder: "Account name", action: "Connect", maxLength: 32, identifier: "managed-account-name",
                           autocapitalization: .none, autocorrection: .no, from: self) { [weak self] raw in
            let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let local = ConnectorAccountRow.aliasProblem(alias, among: app.accounts + app.retired) {
                self?.askAgain { self?.addAccount(draft: alias, problem: local) }
                return
            }
            managed.connect(app.slug, alias: alias)
        }
    }

    /// The prompt that was answered is still leaving the screen: asking again at once would present nothing.
    private func askAgain(_ ask: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            for _ in 0..<40 where self?.presentedViewController != nil { try? await Task.sleep(for: .milliseconds(25)) }
            ask()
        }
    }

    func confirmRemove(_ account: ConnectorAccountRow) {
        guard let managed = page.managed else { return }
        TextPrompt.confirm(title: AccountWords.removeTitle(app: page.name, name: account.name), message: AccountWords.removeBody,
                           action: "Remove", from: self) { managed.remove(account) }
    }

    private func pop() {
        guard navigationController?.topViewController === self else { return }
        navigationController?.popViewController(animated: true)
    }

    func leave() {
        guard page.dirty, page.editable, !page.saving else { pop(); return }
        let alert = UIAlertController(title: "Discard Changes?", message: "Your changes to \(page.name)’s tools haven’t been saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in self?.page.discard(); self?.pop() })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        present(alert, animated: true)
    }

    private func updateLock() {
        guard let navigation = navigationController, navigation.topViewController === self else { return }
        let free = !(page.dirty && page.editable) && !page.saving
        navigation.interactivePopGestureRecognizer?.isEnabled = free
        navigation.interactiveContentPopGestureRecognizer?.isEnabled = free
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        page.appear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateLock()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
        if isMovingFromParent { page.managed?.clearSettled(page.slug) }
    }
}

struct ManagedAppView: View {
    @Bindable var page: ManagedAppPage
    let router: SettingsRouter

    var body: some View {
        List {
            if let managed = page.managed, let app = page.app {
                header(app)
                status(app, managed)
                access(app, managed)
                account(app, managed)
                tools(app, managed)
            } else if page.managed?.phase == .loading {
                Section { SkeletonLine() }
            } else {
                Section {
                    Text("\(page.name) isn’t available for \(page.parent.botName) right now.").foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                }
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("managed.app")
        .onChange(of: page.managed?.policy) { _, _ in page.applyRules() }
        .onChange(of: page.managed?.revision) { _, _ in Task { await page.readTools() } }
        .refreshable {
            await page.managed?.reload()
            await page.readTools()
        }
        .safeAreaInset(edge: .bottom) {
            if page.dirty, page.editable {
                HStack(spacing: 12) {
                    Text(page.draftSummary).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("managed-tools-summary")
                    Button("Discard") { page.discard() }.hqBorderedButtonStyle().disabled(page.saving)
                        .accessibilityIdentifier("managed-tools-discard")
                    Button(page.saving ? "Saving…" : "Save") { page.save() }.hqProminentButtonStyle().disabled(page.saving)
                        .accessibilityIdentifier("managed-tools-save")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .hqGlassEffect(in: .rect(cornerRadius: 22))
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    // MARK: Header

    /// [connectors-ux] The header every Connectors page has (`ConnectorHeader`).
    private func header(_ app: ManagedApp) -> some View {
        ConnectorHeader(title: app.name, state: (app.stateWord, ConnectorTone.of(app)), kind: "Managed by Nous",
                        description: app.description, stateID: "managed-app-state") {
            ManagedLogo(app: app, size: 56)
        }
    }

    // MARK: Status and the next step

    @ViewBuilder private func status(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        let operation = managed.operation(for: app.slug)
        let notice = managed.notices[app.slug]
        let busy = managed.busy.contains(app.slug)
        if let operation, managed.waiting(app.slug) {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finish the sign-in in your browser.").foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("managed-connecting")
                if operation.link != nil {
                    Button("Open the Link Again") { managed.openAgain(app.slug) }.accessibilityIdentifier("managed-open-again")
                }
                Button("Stop Waiting") { managed.stopWaiting(app.slug) }.accessibilityIdentifier("managed-stop-waiting")
                if let notice { Text(notice).font(Font.hq(.subheadline)).foregroundStyle(.orange) }
            }
        } else if let operation, operation.stillOpen, let target = operation.target(app.slug), target.state != .connected, app.state != .connected {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.state == .expired ? "The sign-in link expired." : "The sign-in did not finish.")
                        .font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                    Text(target.detail.isEmpty ? (target.state == .expired ? "Links stay open for a short while. Start again to get a new one." : "Nothing was connected.") : target.detail)
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("managed-connect-ended")
                if !managed.readOnly {
                    Button(busy ? "Starting…" : "Try Again") { managed.connect(app.slug, reconnect: true) }.disabled(busy)
                        .accessibilityIdentifier("managed-try-again")
                }
            }
        } else if let verb = app.verb, !managed.readOnly, !(verb == .turnBackOn && app.ruleable) {
            Section {
                if let reason = app.reason {
                    Text(reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("managed-reason")
                }
                Button {
                    switch verb {
                    case .connect: managed.connect(app.slug)
                    case .reconnect, .tryAgain: managed.connect(app.slug, reconnect: true)
                    case .stopWaiting: managed.stopWaiting(app.slug)
                    case .turnBackOn: managed.setEnabled(app.slug, true)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView() }
                        Text(busy && verb == .connect ? "Opening sign-in…" : verb.title).font(Font.hq(.body).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .hqProminentButtonStyle()
                .buttonBorderShape(.capsule)
                .disabled(busy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .accessibilityIdentifier("managed-verb")
                if let notice { Text(notice).font(Font.hq(.subheadline)).foregroundStyle(.orange) }
            }
        } else if let notice {
            Section { Text(notice).font(Font.hq(.subheadline)).foregroundStyle(.orange) }
        }
    }

    // MARK: Access

    @ViewBuilder private func access(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        if app.ruleable || app.orgLocked {
            Section {
                Toggle(isOn: Binding(get: { managed.pendingEnabled[app.slug] ?? (app.state != .off) },
                                     set: { managed.setEnabled(app.slug, $0) })) {
                    Text("Hermes can use \(app.name)").foregroundStyle(Color.hqLabel)
                }
                .disabled(app.orgLocked || managed.busy.contains(app.slug) || !managed.rulesWritable)
                .accessibilityIdentifier("managed-access-switch")
            } footer: { HQSectionFooter {
                if app.orgLocked {
                    Text("Your organisation turned \(app.name) off.")
                } else if let failure = managed.policyFailure {
                    Text(failure.words(fallback: "Rules cannot be changed right now."))
                } else if managed.readOnly {
                    Text("This gateway is read-only.")
                } else {
                    Text("Follows the Nous account \(page.parent.botName) is signed in with. Bots on the same account share it.")
                }
            } }
        }
    }

    // MARK: Account

    @ViewBuilder private func account(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        if managed.accountNames, app.connected, !app.accounts.isEmpty, app.state != .connecting || app.accounts.count > 1 {
            accounts(app, managed)
        } else if app.connected, app.state != .connecting {
            Section {
                if let label = app.accountLabel, !label.isEmpty {
                    LabeledContent("Signed In As", value: label).accessibilityIdentifier("managed-account-label")
                }
                if let date = Self.date(app.connectedAt) {
                    LabeledContent(app.state == .connected ? "Connected" : "Added", value: date)
                }
                if !managed.readOnly {
                    Button(role: .destructive) {
                        (page.presenter as? ManagedAppController)?.confirmDisconnect()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Disconnect")
                            if managed.busy.contains(app.slug) { ProgressView() }
                        }
                    }
                    .disabled(managed.busy.contains(app.slug))
                    .accessibilityIdentifier("managed-disconnect")
                }
            } header: { HQSectionLabel { Text("Account") } }
        }
    }

    /// [accounts] Every account of the app with its name and status, Rename and Remove on each (the desktop's
    /// `AccountsSection`), the retired ones folded away, and Add Another Account.
    private func accounts(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        let controller = page.presenter as? ManagedAppController
        let busy = managed.busy.contains(app.slug)
        let waiting = managed.waiting(app.slug)
        return Section {
            ForEach(app.accounts) { account in
                AccountRow(account: account, readOnly: managed.readOnly, busy: busy,
                           reconnect: account.needsReconnect && !waiting ? { managed.reconnect(account) } : nil,
                           rename: { controller?.rename(account) },
                           // A lone account's Disconnect sits under it, so its ⋯ doesn't offer Remove… as well.
                           remove: app.accounts.count == 1 ? nil : { controller?.confirmRemove(account) })
            }
            if !app.retired.isEmpty {
                DisclosureGroup {
                    ForEach(app.retired) { account in
                        AccountRow(account: account, readOnly: managed.readOnly, busy: busy, reconnect: nil, rename: nil,
                                   remove: { controller?.confirmRemove(account) })
                    }
                } label: {
                    Text(AccountWords.retired(app.retired.count)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .accessibilityIdentifier("managed-accounts-retired")
            }
            // A lone account keeps the plain Disconnect the one-account page always had, not only Remove… in its ⋯.
            if !managed.readOnly, app.accounts.count == 1 {
                Button(role: .destructive) {
                    controller?.confirmDisconnect()
                } label: {
                    HStack(spacing: 8) {
                        Text("Disconnect")
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("managed-disconnect")
            }
            if !managed.readOnly {
                Button {
                    controller?.addAccount()
                } label: {
                    Label("Add Another Account…", systemImage: "plus")
                }
                .disabled(busy || waiting)
                .accessibilityIdentifier("managed-account-add")
            }
        } header: { HQSectionLabel { Text(app.accounts.count == 1 ? "Account" : "Accounts") } }
    }

    static func date(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = parser.date(from: raw) ?? plain.date(from: raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Tools

    @ViewBuilder private func tools(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        let locked = page.orgLocked
        if !locked.isEmpty, page.toolsState == .loaded {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your organisation turned \(locked.count) tool\(locked.count == 1 ? "" : "s") off.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                    Button("Open the Connectors Admin") { LinkOpener.openOutside(URL(string: "https://portal.nousresearch.com/connectors")!) }
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .accessibilityIdentifier("managed-org-admin")
                }
                .padding(.vertical, 3)
            }
        }
        Section {
            switch page.toolsState {
            case .idle, .reading:
                HStack(spacing: 10) { ProgressView(); Text("Reading the tool list").foregroundStyle(Color.hqLabel2) }
            case .signedOut:
                Text("Sign in to Nous to read the tool list.").foregroundStyle(Color.hqLabel2).padding(.vertical, 3)
            case .gone:
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(app.name) left the catalog.").foregroundStyle(Color.hqLabel)
                    Text("Hermes cannot call it any more.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 3)
            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await page.readTools() } }.hqBorderedButtonStyle().accessibilityIdentifier("managed-tools-retry")
                }
                .padding(.vertical, 3)
            case .loaded:
                toolRows(app, managed)
            }
        } header: { HQSectionLabel {
            Text(app.connected ? "What Hermes May Do with \(app.name)" : "What Hermes Could Do Once You Connect")
        } } footer: { HQSectionFooter {
            if page.toolsState == .loaded {
                if app.state == .off, app.connected { Text("Turn \(app.name) on to change its tools.") }
                else if app.connected, let failure = managed.policyFailure { Text(failure.words(fallback: "Rules cannot be changed right now.")) }
                else if page.stale { Text("Sign in to read the latest tool list.") }
                else { Text("Nous apps follow your account, not the bot.") }
            }
        } }
    }

    @ViewBuilder private func toolRows(_ app: ManagedApp, _ managed: ManagedAppsModel) -> some View {
        let editable = page.editable
        let locked = page.orgLocked
        if page.tools.count > 8 {
            TextField("Search \(page.tools.count) tools", text: $page.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("managed-tools-search")
        }
        if editable, page.search.isEmpty, !page.tools.isEmpty {
            HStack {
                Toggle(isOn: Binding(get: { page.tools.allSatisfy { $0.deprecated || locked.contains($0.slug) || !page.draftOff.contains($0.slug) } },
                                     set: { page.setAll($0) })) {
                    Text("All Tools").font(Font.hq(.body).weight(.semibold))
                }
                .accessibilityHint("Turn every tool on or off")
                .accessibilityIdentifier("managed-tool-switch-all")
            }
            Menu {
                Button("Read Only") { page.quick(offFacets: ["destructive", "write"]) }
                Button("Turn Off Destructive") { page.quick(offFacets: ["destructive"]) }
                Button("Everything On") { page.quick(offFacets: []) }
            } label: {
                Label("Quick Choices", systemImage: "slider.horizontal.3").font(Font.hq(.body))
            }
            .accessibilityIdentifier("managed-tools-quick")
        }
        if page.shownTools.isEmpty {
            Text(page.tools.isEmpty ? "\(app.name) brings no tools." : "No tool matches these filters.").foregroundStyle(Color.hqLabel2)
        }
        ForEach(page.shownTools) { tool in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(Font.hq(.body)).foregroundStyle(tool.deprecated ? Color.hqLabel2 : Color.hqLabel)
                    if !tool.description.isEmpty {
                        Text(tool.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                    }
                    Text(locked.contains(tool.slug) ? "\(ManagedToolWords.facet(tool.facet)) · off by your organisation"
                         : (tool.deprecated ? "\(ManagedToolWords.facet(tool.facet)) · deprecated" : ManagedToolWords.facet(tool.facet)))
                        .font(Font.hq(.caption)).foregroundStyle(tool.facet == "destructive" ? Color.red : Color.hqLabel3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if editable, !locked.contains(tool.slug) {
                    Toggle("", isOn: Binding(get: { !page.draftOff.contains(tool.slug) }, set: { page.setTool(tool.slug, on: $0) }))
                        .labelsHidden()
                        .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                        .disabled(page.saving)
                        .accessibilityLabel(tool.name)
                        .accessibilityIdentifier("managed-tool-switch-\(tool.slug)")
                } else if app.connected, locked.contains(tool.slug) || page.savedOff.contains(tool.slug) {
                    Text("Off").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .contain)
        }
        if page.deprecatedCount > 0 {
            Button(page.showDeprecated ? "Hide \(page.deprecatedCount) Deprecated" : "Show \(page.deprecatedCount) Deprecated") { page.showDeprecated.toggle() }
                .accessibilityIdentifier("managed-tools-deprecated")
        }
    }
}

/// One account of a managed app: its name, the account it signs in as when named, its status, and its actions in a
/// ⋯ menu (also the row's context menu), so a mouse reaches them as well as a finger.
struct AccountRow: View {
    let account: ConnectorAccountRow
    let readOnly: Bool
    let busy: Bool
    let reconnect: (() -> Void)?
    let rename: (() -> Void)?
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                if account.alias != nil, !account.label.isEmpty {
                    Text(account.label).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                if let words = account.statusWords {
                    Text(words).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(tint.opacity(0.14), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("managed-account-\(account.name)")
            if !readOnly {
                Menu { actions } label: {
                    Image(systemName: "ellipsis.circle").font(Font.hq(.body)).foregroundStyle(Color.hqTint)
                        .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
                }
                .disabled(busy)
                .accessibilityLabel("Actions for \(account.name)")
                .accessibilityIdentifier("managed-account-menu-\(account.name)")
            }
        }
        .padding(.vertical, 2)
        .contextMenu { if !readOnly { actions } }
    }

    @ViewBuilder private var actions: some View {
        if let reconnect { Button("Reconnect", systemImage: "arrow.triangle.2.circlepath", action: reconnect) }
        if let rename { Button("Rename…", systemImage: "pencil", action: rename) }
        if let remove { Button("Remove…", systemImage: "trash", role: .destructive, action: remove) }
    }

    private var tint: Color {
        if account.disabled { return Color.hqLabel2 }
        switch account.status {
        case "revoked": return .red
        case "expired", "failed": return .orange
        default: return Color.hqLabel2
        }
    }
}
