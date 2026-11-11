// Capabilities › Connectors (docs/spec/3x-capabilities.md §5): the list, and a page per connector with its status,
// sign-in, its tools (a draft saved as tool rules) and Advanced.

import SwiftUI
import UIKit

// [directory] The tab's sections (ConnectorsSections) live in ConnectorDirectory.swift.

struct ConnectorRow: View {
    let server: McpServer
    var title: String? = nil   // [directory] the catalog's name for it ("Linear"), else the config key
    var entry: McpCatalogEntry? = nil
    let busy: Bool
    let readOnly: Bool
    let toggle: (Bool) -> Void
    let open: () -> Void

    /// A plugin's connector is switched with its plugin, not here.
    private var viaPlugin: Bool { server.source == "plugin" }

    /// [connectors-ux] "Connected · 12 tools", "Off", "Needs sign-in"; a plugin's ends "· Plugin" (its page names it).
    static func words(_ server: McpServer) -> String {
        var line = CapabilitiesModel.statusLine(server)
        if server.source == "plugin", let cut = line.range(of: " · Added by the ") { line = String(line[..<cut.lowerBound]) + " · Plugin" }
        return line
    }

    /// [connector-rows] Owner 2026-11-10 (design pick 26): the row drops the word "Connected" (its green dot says
    /// it) and starts at the tool count, "12 tools · Plugin". Every other state keeps its words; VoiceOver, which
    /// has no dot, still hears the whole line.
    static func shownWords(_ server: McpServer) -> String {
        let line = words(server)
        return line.hasPrefix("Connected · ") ? String(line.dropFirst("Connected · ".count)) : line
    }

    var body: some View {
        // [mac] Stress test 2026-10-28 #22, #92, and [connectors-ux] on every device: a row carries a switch or a chevron,
        // not both (the whole row opens the page). A plugin's connector has no switch here at all: it was a dimmed one
        // with a line under it saying why ("Turned on and off with its plugin."), which read as broken in dark. Its
        // page says which plugin and opens Plugins.
        let switchable = !readOnly && !viaPlugin
        HStack(spacing: 16) {
            Button(action: open) {
                HStack(spacing: 12) {
                    CatalogLogo(server: server, entry: entry, size: 34)   // [directory]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title ?? server.name).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)   // [mac] regular on the Mac, as Skills' names (Mac polish #95)
                        ConnectorStatusLine(words: Self.shownWords(server), tone: ConnectorTone.of(server))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.words(server))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !switchable {
                        SettingsChevron()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connector-row-\(server.name)")
            if switchable {
                Toggle("", isOn: Binding(get: { server.enabled }, set: { toggle($0) }))
                    .labelsHidden()
                    .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                    .disabled(busy)
                    .accessibilityLabel(title ?? server.name)
                    .accessibilityIdentifier("mcp-switch-\(server.name)")
            }
        }
        .padding(.vertical, Theme.isDesktop ? 3 : 0) // [compact] iOS look: the list row's own inset only
    }
}

// MARK: - Page model

@MainActor @Observable
final class ConnectorPageModel {
    let parent: CapabilitiesModel
    let name: String
    let profile: String
    let bot: String
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored var onGone: (() -> Void)?

    enum ToolsState: Equatable { case idle, reading, failed, loaded }
    var toolsState = ToolsState.idle
    var tools: [McpTool] = []
    /// The saved entry's rules (nil until read) and the draft of names switched off.
    var entry: JSONValue?
    var entryRead = false
    var redacted = false
    var savedOff: Set<String> = []
    var draftOff: Set<String> = []
    var saving = false
    var checking = false
    var signingIn = false
    var probeError: String?
    var needsAuthProbe = false
    var search = ""
    /// Kept on screen when a save lost the connector, so the owner can read what it was (§5.5-b step 5).
    var lostEntry: JSONValue?
    /// Back was tapped while a Save was on its way: the page leaves when the gateway has answered (3x §17.5 f).
    @ObservationIgnored var leaveAfterSave = false
    @ObservationIgnored var onSaved: (() -> Void)?
    /// The draft or a save changed: the page re-reads whether swipe-back is allowed.
    @ObservationIgnored var lockChanged: (() -> Void)?
    @ObservationIgnored private var signIn: McpSignIn?

    init(parent: CapabilitiesModel, server: McpServer) {
        self.parent = parent
        name = server.name
        profile = parent.profile
        bot = parent.botName
    }

    var store: CapabilitiesStore? { parent.store }
    var server: McpServer? { parent.profile == profile ? parent.servers?.first { $0.name == name } : nil }
    var isPlugin: Bool { server?.source == "plugin" }
    var readOnly: Bool { parent.readOnly }
    var canEditTools: Bool { !isPlugin && !readOnly && !redacted && entry != nil }
    var dirty: Bool { draftOff != savedOff }

    enum Status { case ok, probing, off, needsAuth, error, unknown }
    var status: Status {
        guard let server else { return .unknown }
        if !server.enabled { return .off }
        if needsAuthProbe || ServerIssues.kind(of: server) == .needsAuth { return .needsAuth }
        switch server.status {
        case "connected": return .ok
        case "connecting": return .probing
        case "failed": return .error
        default: return .unknown
        }
    }

    /// `canAuthenticate`: a URL server without custom headers, signed in with OAuth (or with no sign-in set, when it asks).
    var canAuthenticate: Bool {
        guard let server, !isPlugin, !readOnly, server.url != nil || server.transport == "http", !server.hasHeaders else { return false }
        if server.auth == "oauth" { return status == .needsAuth || status == .error }
        return (server.auth ?? "").isEmpty && status == .needsAuth
    }

    var reason: String? {
        guard let server else { return nil }
        switch status {
        case .off: return "Turn it on to read the tools it brings."
        case .needsAuth: return "Sign in to let this server answer."
        case .error: return ConnectorTitle.failureDetail(probeError ?? "", hasCommand: server.command != nil || server.transport == "stdio",
                                                         hasURL: server.url != nil || server.transport == "http")
        default: return nil
        }
    }

    func appear() {
        Task {
            await readEntry()
            if toolsState == .idle { await readTools() }
        }
    }

    func disappear() { signIn?.cancel() }

    func readEntry() async {
        guard let store, !isPlugin else { entryRead = true; return }
        do {
            let value = try await store.mcpEntry(name, profile: profile)
            entry = value
            redacted = value.map(McpToolFilter.looksRedacted) ?? false
            entryRead = true
            applyRules()
        } catch {
            entryRead = true
        }
    }

    private func applyRules() {
        let off = Set(tools.map(\.name).filter { !McpToolFilter.isEnabled(entry, $0) })
        let wasDirty = dirty
        savedOff = off
        if !wasDirty { draftOff = off }
    }

    func readTools() async {
        guard let store, let server, server.enabled, status != .needsAuth else { return }
        toolsState = .reading
        let start = ContinuousClock.now
        do {
            let probe = try await store.mcpTest(name, profile: profile)
            if probe.oauthNeeded {
                needsAuthProbe = true; toolsState = .idle
                AppLog.trace("connect", "connector \(name) probe: needs auth")
                return
            }
            needsAuthProbe = false
            if probe.ok {
                tools = probe.tools
                probeError = nil
                toolsState = .loaded
                applyRules()
                ServerIssues.shared.clear(profile: profile, name: name)
                AppLog.trace("connect", "connector \(name) probe ok in \(AppLog.ms(since: start)) ms: \(probe.tools.count) tools")
            } else {
                probeError = probe.error
                toolsState = .failed
                AppLog.note("connect", "connector \(name) probe failed in \(AppLog.ms(since: start)) ms: \(probe.error ?? "")")
            }
        } catch {
            probeError = CapabilitiesStore.detail(error)
            toolsState = .failed
            AppLog.note("connect", "connector \(name) probe errored after \(AppLog.ms(since: start)) ms: \(probeError ?? "")")
        }
    }

    /// "Try Again" / "Check Now": probe, then re-read the status.
    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            await readTools()
            await parent.reloadServers()
        }
    }

    func setEnabled(_ on: Bool) {
        guard let server else { return }
        parent.setMcp(server, enabled: on)
        if on {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await readTools()
            }
        } else {
            tools = []; toolsState = .idle; needsAuthProbe = false
        }
    }

    func startSignIn() {
        guard let store, !signingIn else { return }
        signingIn = true
        let flow = McpSignIn(store: store)
        signIn = flow
        let start = ContinuousClock.now
        AppLog.trace("connect", "connector \(name) sign-in started")
        Task {
            let outcome = await flow.run(server: name, profile: profile, window: presenter?.view.window)
            signingIn = false
            signIn = nil
            switch outcome {
            case .signedIn:
                AppLog.trace("connect", "connector \(name) sign-in ok in \(AppLog.ms(since: start)) ms")
                Haptics.play(.success)
                needsAuthProbe = false
                ServerIssues.shared.clear(profile: profile, name: name)
                await store.reloadMcp()
                await parent.reloadServers()
                await readTools()
            case .cancelled:
                AppLog.trace("connect", "connector \(name) sign-in cancelled after \(AppLog.ms(since: start)) ms")
            case .failed(let reason):
                AppLog.note("connect", "connector \(name) sign-in failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Sign In to \(name)", reason: reason, from: presenter)
            }
        }
    }

    // MARK: Tool rules (a draft)

    var shownTools: [McpTool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tools }
        return tools.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
    }

    var draftSummary: String {
        let off = draftOff.count
        let back = savedOff.subtracting(draftOff).count
        return "\(CapabilitiesModel.plural(off, "tool", "tools")) off, \(back == 0 ? "none" : String(back)) back on"
    }

    func setTool(_ tool: String, on: Bool) {
        Haptics.play(.selection)
        if on { draftOff.remove(tool) } else { draftOff.insert(tool) }
        lockChanged?()
    }

    func setAll(_ on: Bool) {
        Haptics.play(.selection)
        draftOff = on ? [] : Set(tools.map(\.name))
        lockChanged?()
    }

    func discard() { draftOff = savedOff; lockChanged?() }

    func save() {
        guard let store, dirty, !saving, canEditTools else { return }
        saving = true
        let disabled = tools.map(\.name).filter(draftOff.contains), discovered = tools.map(\.name)
        let before = entry
        lockChanged?()
        let start = ContinuousClock.now
        Task {
            var saved = false
            defer {
                saving = false
                lockChanged?()
                if leaveAfterSave { leaveAfterSave = false; if saved { onSaved?() } }
            }
            do {
                switch try await store.saveToolRules(name, disabled: disabled, discovered: discovered, profile: profile) {
                case .saved, .unchanged:
                    Haptics.play(.success)
                    savedOff = draftOff
                    saved = true
                    await readEntry()
                    await parent.reloadServers()
                    AppLog.trace("connect", "connector \(name) tool rules saved in \(AppLog.ms(since: start)) ms, \(disabled.count) disabled of \(discovered.count)")
                case .gone:
                    AppLog.note("connect", "connector \(name) tool rules save: connector gone")
                    FailureAlert.present(title: "Couldn’t Save", reason: "This connector is no longer on your gateway.", from: presenter)
                    await parent.reloadServers()
                    onGone?()
                case .rolledBack(let reason):
                    AppLog.note("connect", "connector \(name) tool rules save rolled back: \(McpEntryMask.phone.text(reason))")
                    FailureAlert.present(title: "Couldn’t Save", reason: "Those tool rules were not saved. \(McpEntryMask.phone.text(reason))", from: presenter)
                    await parent.reloadServers()
                case .lost(let reason):
                    lostEntry = before
                    AppLog.note("connect", "connector \(name) tool rules save lost the entry: \(McpEntryMask.phone.text(reason))")
                    FailureAlert.present(title: "Couldn’t Save",
                                         reason: "\(name) was taken off \(bot) while saving and could not be put back. Add it again under Connectors.",
                                         detail: McpEntryMask.phone.text(reason), from: presenter)
                    await parent.reloadServers()
                }
            } catch let error as BotWriteError {
                if error.reason.contains("can be changed on the computer running Hermes") { redacted = true }
                AppLog.note("connect", "connector \(name) tool rules save failed after \(AppLog.ms(since: start)) ms: \(error.reason)")
                FailureAlert.present(title: "Couldn’t Save", reason: error.reason, from: presenter)
            } catch {
                let reason = McpEntryMask.phone.text(CapabilitiesStore.detail(error))
                AppLog.note("connect", "connector \(name) tool rules save failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Save", reason: "Those tool rules were not saved. \(reason)",
                                     from: presenter)
            }
        }
    }

    func remove(then done: @escaping () -> Void) {
        guard let store else { return }
        let start = ContinuousClock.now
        Task {
            do {
                try await store.mcpRemove(name, profile: profile)
                await store.reloadMcp()
                ServerIssues.shared.clear(profile: profile, name: name)
                await parent.reloadServers()
                AppLog.trace("connect", "connector \(name) removed in \(AppLog.ms(since: start)) ms")
                Haptics.play(.success)
                done()
            } catch {
                let reason = McpEntryMask.phone.text(CapabilitiesStore.detail(error))
                AppLog.note("connect", "connector \(name) remove failed after \(AppLog.ms(since: start)) ms: \(reason)")
                FailureAlert.present(title: "Couldn’t Remove \(name)", reason: reason, from: presenter)
            }
        }
    }
}

// MARK: - Page

final class ConnectorPageController: UIHostingController<HQScaledRoot<ConnectorPageView>> {
    let page: ConnectorPageModel

    init(model: CapabilitiesModel, server: McpServer, router: SettingsRouter) {
        page = ConnectorPageModel(parent: model, server: server)
        super.init(rootView: HQScaledRoot(ConnectorPageView(page: page, router: router)))
        title = model.title(of: server)
        navigationItem.largeTitleDisplayMode = .never
        page.presenter = self
        page.onGone = { [weak self] in
            guard let self, let navigation = self.navigationController, let index = navigation.viewControllers.firstIndex(of: self), index > 0 else { return }
            navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
        }
        let refresh = UIAction(title: "Refresh Tools", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.page.check() }
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [refresh]))
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "connector.more"
        navigationItem.rightBarButtonItem = item
        // [capabilities] 3x §17.5 f: leaving with unsaved tool changes asks first; while a Save is on its way, Back waits.
        navigationItem.backAction = UIAction { [weak self] _ in self?.leave() }
        page.onSaved = { [weak self] in self?.pop() }
        page.lockChanged = { [weak self] in self?.updateLock() }
    }

    private func pop() {
        guard navigationController?.topViewController === self else { return }
        navigationController?.popViewController(animated: true)
    }

    /// Back: the question when there are unsaved changes (the words the plugin page uses), else straight back.
    func leave() {
        if page.saving { page.leaveAfterSave = true; return }
        guard page.dirty, page.canEditTools else { pop(); return }
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Discard Changes?", message: "Your changes to \(page.name)’s tools haven’t been saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in
            guard let self, !self.page.saving else { return }
            self.page.discard()
            self.pop()
        })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        present(alert, animated: true)
    }

    /// Swipe-back is held while there are unsaved changes or a Save is on its way (the app's rule for editors,
    /// `EditingPage.updateModalLock`): the Back button is then the one way out, and it asks.
    private func updateLock() {
        guard let navigation = navigationController, navigation.topViewController === self else { return }
        let free = !(page.dirty && page.canEditTools) && !page.saving
        navigation.interactivePopGestureRecognizer?.isEnabled = free
        navigation.interactiveContentPopGestureRecognizer?.isEnabled = free
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateLock()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The recognizers belong to the stack: the next page gets them back.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        page.appear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController == nil { page.disappear() }
    }
}

struct ConnectorPageView: View {
    @Bindable var page: ConnectorPageModel
    let router: SettingsRouter

    var body: some View {
        List {
            if let server = page.server {
                header(server)
                status(server)
                if !page.readOnly, !page.isPlugin {
                    Section {
                        Toggle("On for \(page.bot)", isOn: Binding(get: { server.enabled }, set: { page.setEnabled($0) }))
                            .disabled(page.parent.mcpToggling.contains(server.name))
                            .accessibilityIdentifier("connector-page-switch")
                    }
                }
                tools(server)
                Section {
                    Button {
                        router.push(ConnectorAdvancedController(page: page, router: router))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Advanced").foregroundStyle(Color.hqLabel)
                                Text("The configuration and logs").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            }
                            Spacer()
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connector-advanced")
                    if page.isPlugin {
                        // [cap-pages] Plugins is its own page now: it opens over this one, for the same bot.
                        Button("Open Plugins") {
                            router.push(CapabilitiesViewController(services: page.parent.services, profile: page.profile, tab: .plugins))
                        }
                        .accessibilityIdentifier("connector-open-plugins")
                    }
                } footer: { HQSectionFooter {
                    if page.isPlugin, let plugin = server.plugin { Text("Provided by the \(plugin) plugin.") }
                } }
            } else {
                Section { Text("This connector is no longer on your gateway.").foregroundStyle(Color.hqLabel2).padding(.vertical, 12) }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("connector-page")
        .safeAreaInset(edge: .bottom) {
            if page.dirty {
                HStack(spacing: 12) {
                    Text(page.draftSummary).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mcp-tools-summary")
                    Button("Discard") { page.discard() }.hqBorderedButtonStyle().disabled(page.saving)
                        .accessibilityIdentifier("mcp-tools-discard")
                    Button(page.saving ? "Saving…" : "Save") { page.save() }.hqProminentButtonStyle().disabled(page.saving)
                        .accessibilityIdentifier("mcp-tools-save")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .hqGlassEffect(in: .rect(cornerRadius: 22))
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    /// [connectors-ux] The header every Connectors page has: the logo and the catalog's name (it had none; the page
    /// opened on a dot and "Connected · 12 tools"), the state as a badge, where it runs, what it does.
    private func header(_ server: McpServer) -> some View {
        let entry = page.parent.catalogEntry(for: server)
        let kind = page.isPlugin ? server.plugin.map { "From the \(DisplayName.title($0)) plugin" } : server.url.flatMap { URL(string: $0)?.host }
        return ConnectorHeader(title: page.parent.title(of: server), state: (words(page.status, server), tone(page.status)), kind: kind,
                               description: entry?.description ?? "", stateID: "connector-page-status") {
            CatalogLogo(server: server, entry: entry, size: 56)
        }
    }

    /// Why it isn't working and what to do: only when there is something to say or tap.
    @ViewBuilder private func status(_ server: McpServer) -> some View {
        let state = page.status
        let signIn = (state == .needsAuth || (state == .error && page.canAuthenticate)) && (page.canAuthenticate || state == .needsAuth)
            && !page.readOnly && !page.isPlugin
        let retry = state == .error || state == .unknown
        if page.reason != nil || signIn || retry {
            Section {
                if let reason = page.reason {
                    Text(reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 3)
                        .accessibilityIdentifier("connector-page-reason")
                }
                if signIn {
                    Button(page.signingIn ? "Signing in…" : "Sign In") { page.startSignIn() }
                        .disabled(page.signingIn)
                        .accessibilityIdentifier("connector-signin")
                }
                if retry {
                    Button(page.checking ? "Checking…" : (state == .error ? "Try Again" : "Check Now")) { page.check() }
                        .disabled(page.checking)
                        .accessibilityIdentifier("connector-retry")
                }
            }
        }
    }

    private func tone(_ state: ConnectorPageModel.Status) -> ConnectorTone {
        switch state {
        case .ok: .good
        case .probing, .unknown: .busy
        case .off: .quiet
        case .needsAuth: .warn
        case .error: .bad
        }
    }

    private func words(_ state: ConnectorPageModel.Status, _ server: McpServer) -> String {
        switch state {
        case .ok: "Connected · \(CapabilitiesModel.plural(server.tools ?? page.tools.count, "tool", "tools"))"
        case .probing: "Connecting…"
        case .off: "Off"
        case .needsAuth: "Needs sign-in"
        case .error: "Couldn’t connect"
        case .unknown: "Starts when needed"
        }
    }

    @ViewBuilder private func tools(_ server: McpServer) -> some View {
        Section {
            if !server.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(page.parent.title(of: server)) is off.").foregroundStyle(Color.hqLabel)
                    Text("Turn it on with the switch above to read the tools it brings.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 3)
            } else if page.status == .needsAuth {
                Text("Sign in to \(page.parent.title(of: server)) to read its tools.").foregroundStyle(Color.hqLabel2).padding(.vertical, 3)
            } else {
                switch page.toolsState {
                case .idle, .reading:
                    HStack(spacing: 10) { ProgressView(); Text("Reading the tool list").foregroundStyle(Color.hqLabel2) }
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tool list unavailable.").foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { page.check() }.hqBorderedButtonStyle().accessibilityIdentifier("mcp-tools-retry")
                    }
                    .padding(.vertical, 3)
                case .loaded:
                    toolRows
                }
            }
        } header: { HQSectionLabel {
            Text(page.toolsState == .loaded && server.enabled ? CapabilitiesModel.plural(page.tools.count, "Tool", "Tools") : "Tools")
        } } footer: { HQSectionFooter {
            if page.redacted { Text("This connector’s tool list can be changed on \(HostWord.phrase).") }
        } }
    }

    @ViewBuilder private var toolRows: some View {
        let editable = page.canEditTools
        if page.tools.count > 8 {
            TextField("Search \(page.tools.count) tools", text: $page.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("mcp-tools-search")
        }
        if editable, page.search.isEmpty, !page.tools.isEmpty {
            Toggle(isOn: Binding(get: { page.draftOff.isEmpty }, set: { page.setAll($0) })) {
                Text("All Tools").font(Font.hq(.body).weight(.semibold))
            }
            .accessibilityHint("Turn every tool on or off")
            .accessibilityIdentifier("mcp-tool-switch-all")
        }
        if page.shownTools.isEmpty {
            Text(page.tools.isEmpty ? "This connector brings no tools." : "No tool matches these filters.").foregroundStyle(Color.hqLabel2)
        }
        ForEach(page.shownTools) { tool in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(Font.hq(.body).monospaced()).foregroundStyle(Color.hqLabel)
                    if !tool.description.isEmpty {
                        Text(tool.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if editable {
                    Toggle("", isOn: Binding(get: { !page.draftOff.contains(tool.name) }, set: { page.setTool(tool.name, on: $0) }))
                        .labelsHidden()
                        .hqMacRowSwitch()   // [mac] Stress test 2026-10-28 round 6
                        .disabled(page.saving)
                        .accessibilityLabel(tool.name)
                        .accessibilityIdentifier("mcp-tool-switch-\(tool.name)")
                } else if !McpToolFilter.isEnabled(page.entry, tool.name) {
                    Text("Off").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.vertical, 3)
        }
    }
}
