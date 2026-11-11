// More › Status & Maintenance (docs/spec/3x-morepages.md §15, D-M12): the gateway's status (version, messaging, its
// platforms, Restart Gateway, Recent Logs, Update Hermes), then its maintenance actions, as sections of one page. The
// page's model and the factory More, More search and Settings › Gateway use.
// [status-page] It was Command Center, with System · Usage · Maintenance tabs (owner 2026-11-03: one home per page;
// tabs only flip between lists of one kind, never hold different jobs). Usage is a More page of its own
// (CommandCenterUsage.swift). The old name stays in the code's ids and types (`CommandCenterNames`).

import SwiftUI
import UIKit

extension MorePages {
    static func installCommandCenter() {
        factories["command-center"] = { context in CommandCenter.make(context: context) }
        // The Gateway page's Status & Maintenance row (UX study #189): where Restart and Update live.
        SettingsHooks.commandCenter = {
            guard let context = MorePages.context, !MoreAvailability.unavailable(context.account).contains("command-center") else { return nil }
            return { CommandCenter.make(context: context) }
        }
    }
}

@MainActor
enum CommandCenter {
    /// The page (More's row, More search's Restart Gateway and Update Hermes, Settings › Gateway's row).
    static func make(context: MorePages.Context) -> UIViewController {
        let model = CommandCenterModel(context: context)
        let page = MorePageController(title: CommandCenterNames.page, identifier: "command-center.page", CommandCenterView(model: model))
        model.host = page
        page.retained = [model]
        page.onAppear = { [weak model] in model?.appear() }
        page.onDisappear = { [weak model] in model?.disappear() }
        return page
    }
}

@MainActor @Observable
final class CommandCenterModel {
    enum Load: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored let api: CommandCenterAPI
    @ObservationIgnored weak var host: UIViewController?

    private(set) var online: Bool

    // System
    private(set) var status: GatewayStatusReport?
    private(set) var statusLoad: Load = .loading
    private(set) var statusRefreshFailed = false
    private(set) var update: HermesUpdateCheck?
    private(set) var updateChecked = false
    let restart: GatewayActionRun

    // Maintenance
    let maintenance: GatewayActionRun
    private(set) var maintenanceAction: MaintenanceAction?

    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var appeared = false

    init(context: MorePages.Context) {
        self.context = context
        api = CommandCenterAPI(client: context.client)
        online = context.isOnline
        restart = GatewayActionRun(api: api.actions)
        maintenance = GatewayActionRun(api: api.actions)
        maintenance.interval = .milliseconds(1200)      // the web's ACTION_POLL_MS
        restart.onFinish = { [weak self] ok in
            if ok { PagesHaptics.success() } else { PagesHaptics.error() }   // as the maintenance actions
            Task { await self?.loadStatus() }
        }
        maintenance.onFinish = { ok in if ok { PagesHaptics.success() } else { PagesHaptics.error() } }
    }

    var readOnly: Bool { context.readOnly }
    /// [update-flow] This gateway's update, in the shared Update sheet (HermesUpdate.swift), while it runs or until its
    /// ending is seen.
    var updateRun: HermesUpdate? { HermesUpdateCenter.shared.run(context.account.id) }
    var updating: Bool { updateRun?.isRunning ?? false }
    var anyActionBusy: Bool { restart.isBusy || updating }
    /// Audit 863 (08d-1): Restart and Update wait for a maintenance action (a backup cut off by a restart), and a
    /// maintenance action waits for them.
    var canStartAction: Bool { !readOnly && online && !anyActionBusy && !maintenance.isBusy }
    var canStartMaintenance: Bool { canStartAction }

    // MARK: Lifecycle

    func appear() {
        connectionTask?.cancel()
        let client = context.client
        connectionTask = Task { [weak self] in
            for await state in client.connectionStates() {
                guard let self, !Task.isCancelled else { return }
                let ready = state == .ready
                if ready != self.online {
                    self.online = ready
                    // Back after a drop: what the page shows may be older than the gateway.
                    if ready, self.status != nil, !self.anyActionBusy { await self.loadStatus() }
                }
            }
        }
        guard !appeared else { return }
        appeared = true
        Task { await loadStatus() }
        Task { await checkUpdate(force: false) }
        if !readOnly { Task { await resumeActions() } }
    }

    func disappear() {
        connectionTask?.cancel()
        connectionTask = nil
    }

    func refresh() async {
        await loadStatus()
        await checkUpdate(force: true)
    }

    // MARK: System

    func loadStatus() async {
        do {
            status = try await api.status()
            statusLoad = .ready
            statusRefreshFailed = false
        } catch {
            if status == nil { statusLoad = .failed(PagesREST.reason(error)) } else { statusRefreshFailed = !anyActionBusy }
        }
    }

    func retryStatus() {
        statusLoad = .loading
        Task { await loadStatus(); await checkUpdate(force: false) }
    }

    func checkUpdate(force: Bool) async {
        if let answer = try? await api.updateCheck(force: force) {
            update = answer
            HermesUpdateCenter.shared.note(answer, for: context.account.id)   // [update-flow] More's row, Settings' rows
        }
        updateChecked = true
    }

    /// [update-flow] The shared run ended: what the page shows is older than the gateway.
    func updateEnded() {
        Task { await loadStatus(); await checkUpdate(force: true) }
    }

    /// Stress test 2026-10-28 #20: "Couldn’t Check" had no way to ask again short of leaving the page.
    func retryUpdateCheck() {
        updateChecked = false   // reads "Checking…" while it asks
        if update?.couldNotCheck == true { update = nil }   // a failed answer would keep saying "Couldn’t Check"
        Task { await checkUpdate(force: true) }
    }

    /// An action that was already running when the page opened (the app was relaunched mid-restart): pick it up from
    /// its status instead of showing an idle row.
    private func resumeActions() async {
        let actions = api.actions
        if !restart.isBusy, let answer = try? await actions.status("gateway-restart"), answer.running, !restart.isBusy {
            restart.start { "gateway-restart" }
        }
        // [update-flow] A running update is followed in the shared Update sheet's state (its row says "Updating …").
        if !updating, let answer = try? await actions.status("hermes-update"), answer.running, !updating {
            HermesUpdateCenter.shared.attach(context.account)
        }
    }

    func askRestart() {
        guard canStartAction else { return }
        GatewayRestart.confirm(from: host) { [weak self] in
            guard let self, self.canStartAction else { return }
            AppLog.note("command-center", "restart gateway")
            let actions = self.api.actions
            self.restart.start { try await actions.restart() }
        }
    }

    /// [update-flow] The Update sheet: it names this gateway, checks, and asks before anything changes.
    func askUpdate() {
        guard !readOnly, online, !restart.isBusy, !maintenance.isBusy else { return }
        AppLog.note("command-center", "update hermes")
        HermesUpdateCenter.shared.update(context.account, from: host)
    }

    /// Messaging is listed on this gateway (its page is where a failing app is fixed).
    var canOpenMessaging: Bool { MorePages.factories["messaging"] != nil && !MoreAvailability.unavailable(context.account).contains("messaging") }

    /// A failing platform row: Messaging, on the bot it last showed (its picker changes it).
    func openMessaging() {
        guard let page = MorePages.factories["messaging"]?(context) else { return }
        page.navigationItem.largeTitleDisplayMode = .never
        MacDash.closes(page)
        host?.navigationController?.pushViewController(page, animated: true)
    }

    func openLogs() {
        let page = CommandCenterLogs.make(api: api)
        MacDash.closes(page)
        host?.navigationController?.pushViewController(page, animated: true)
    }

    // MARK: Maintenance

    func run(_ action: MaintenanceAction) {
        guard canStartMaintenance else { return }
        AppLog.note("command-center", "maintenance \(action.rawValue)")
        maintenanceAction = action
        maintenance.reset()
        let actions = api.actions
        maintenance.start { try await action.start(actions) }
        openMaintenanceOutput()
    }

    func openMaintenanceOutput() {
        guard let action = maintenanceAction else { return }
        let page = ActionOutput.make(title: action.outputTitle, run: maintenance, words: ActionWords.maintenance)
        MacDash.closes(page)
        host?.navigationController?.pushViewController(page, animated: true)
    }
}

// MARK: - The page

struct CommandCenterView: View {
    @Bindable var model: CommandCenterModel
    /// [mac-tools] The Mac page's width: the dashboard shows from `StatusDashboard.wideAt`.
    @State private var width: CGFloat = 0
    private var dashboard: Bool { DeviceWord.isMac && width >= StatusDashboard.wideAt }

    var body: some View {
        Group {
            switch model.statusLoad {
            case .failed(let reason) where dashboard && !model.readOnly && reason != MoreWire.olderHermes:
                StatusDashboard(model: model, failed: reason)
            case .ready where dashboard:
                StatusDashboard(model: model)
            case .loading:
                MoreSkeleton(label: "Loading \(CommandCenterNames.page)…") { model.retryStatus() }
            case .failed(let reason) where !model.readOnly && reason != MoreWire.olderHermes:
                // [status-page] The status couldn't be read: the reason and Try Again where it would be, and Maintenance
                // still under it (its tab opened without the status, and a gateway that won't answer is when it's wanted).
                page {
                    CommandCenterStatusFailed(reason: reason) { model.retryStatus() }
                    CommandCenterMaintenance(model: model)
                }
            case .failed(let reason):
                MoreErrorState(title: "Couldn’t Load \(CommandCenterNames.page)", reason: reason) { model.retryStatus() }
            case .ready:
                page {
                    CommandCenterSystem(model: model)
                    // [status-page] Maintenance under the status on the same page, headed as its own part. A read-only
                    // gateway has none: every row in it is an action.
                    if !model.readOnly { CommandCenterMaintenance(model: model) }
                }
            }
        }
        .background(Color.hqGroupedPage)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
    }

    private func page(@ViewBuilder _ sections: () -> some View) -> some View {
        List { sections() }
            .hqMacForm()   // [mac] Stress test 2026-10-28 #8: the rows at a readable width
            .hqGroupedPage()
            .listStyle(.insetGrouped)
            .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // [mac] Stress test 2026-10-28 #53
            .refreshable { await model.refresh() }
            .accessibilityIdentifier("command-center.list")
    }
}

/// [status-page] The status's place when its first read failed (Maintenance follows it on the page).
struct CommandCenterStatusFailed: View {
    var reason: String
    var retry: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn’t Load Status", systemImage: "exclamationmark.triangle")
                    .font(Font.hq(.headline))
                Text(reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("more.page.retry")
            }
            .padding(.vertical, 6)
        } header: { HQSectionLabel { Text("Status") } }
    }
}

// MARK: - System

struct CommandCenterSystem: View {
    @Bindable var model: CommandCenterModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let status = model.status {
            if model.statusRefreshFailed {
                Section {
                    HStack(spacing: 12) {
                        Text("Couldn’t refresh. Showing the last status.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Try Again") { Task { await model.loadStatus() } }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("command-center.refresh-failed")
                }
            }
            Section {
                LabeledContent("Version", value: status.versionWords)
                    .accessibilityIdentifier("command-center.version")
                // The value goes under its label at accessibility sizes, like the LabeledContent rows around it (side by
                // side both words broke mid-word).
                let stacked = typeSize.isAccessibilitySize
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                layout {
                    Text("Messaging").foregroundStyle(Color.hqLabel)
                    if !stacked { Spacer(minLength: 12) }
                    if let running = status.gatewayRunning {
                        MoreStatusLine(text: status.gatewayWords, color: running ? .green : Color.hqRed)
                    } else {
                        Text("—").foregroundStyle(Color.hqLabel2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("command-center.gateway")
                LabeledContent("Active Sessions", value: status.sessionsWords)
                    .accessibilityIdentifier("command-center.sessions")
            } header: { HQSectionLabel {
                Text("Status")
            } }
            if !status.platforms.isEmpty {
                Section {
                    ForEach(status.platforms) { platform in
                        // UX study #118: a failing app opens Messaging, where it is fixed; a working one stays a plain row.
                        // A disconnected one is fixed there too (#106).
                        let opensMessaging = (platform.isDown || !platform.isUp) && model.canOpenMessaging
                        if opensMessaging {
                            Button { model.openMessaging() } label: {
                                platformRow(platform, chevron: true)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Opens Messaging")
                            .accessibilityIdentifier("command-center.platform.\(platform.id)")
                        } else {
                            // Item 7: every row keeps the chevron's column, even where it opens nothing,
                            // so the statuses line up across rows.
                            platformRow(platform, chevron: false)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("command-center.platform.\(platform.id)")
                        }
                    }
                } header: { HQSectionLabel {
                    Text("Messaging Platforms")
                } } footer: { HQSectionFooter {
                    // The scope: Messaging shows each bot's own apps.
                    Text("For the whole gateway, all bots together. Each bot’s apps are set up in Messaging.")
                } }
            }
            // [status-tidy] Owner 2026-11-10 (design pick 15): on the iPhone and iPad these rows are part of the one
            // Maintenance list below (`CommandCenterMaintenance`), each with its mark. The Mac keeps its form, and a
            // read-only gateway (which has no Maintenance list) keeps them here.
            if !Self.oneList(model) {
                Section {
                    if !model.readOnly { restartRow }
                    NavRow(title: "Recent Logs") { model.openLogs() }
                        .accessibilityIdentifier("command-center.logs")
                } footer: { HQSectionFooter {
                    if !model.readOnly, !model.online, !model.anyActionBusy { Text(MorePages.offlineFooter) }
                } }
                updateSection(status)
            }
        }
    }

    /// [status-tidy] Restart, Update, the maintenance actions and Recent Logs as one list.
    static func oneList(_ model: CommandCenterModel) -> Bool { !DeviceWord.isMac && !model.readOnly }

    /// [mac-ui-issues] The name, the status and the chevron share one line (the chevron sat 6 px above "Error"), and an
    /// error runs under them at the row's whole width (it wrapped at half the row, beside the status).
    private func platformRow(_ platform: GatewayStatusReport.Platform, chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(platform.name).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                MoreStatusLine(text: platform.words, color: platform.isUp ? .green : (platform.isDown ? Color.hqRed : Color.hqLabel2))
                SettingsChevron().opacity(chevron ? 1 : 0)
            }
            if let error = platform.error {
                Text(error).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, platform.error == nil ? 0 : 6)
    }

    @ViewBuilder var restartRow: some View {
        if model.restart.phase == .idle, DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #51: a push button at the row's trailing edge; it asks first, so "…".
            // [mac] Stress test 2026-10-28 #10 (then Command Center): the button sat alone at the right of an empty row above
            // Recent Logs. It is now a labelled row, "Gateway" leading with what a restart does, the button trailing.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateway").foregroundStyle(Color.hqLabel)
                    Text("Restarting stops replies for a moment.")
                        .hqMacFont(MacType.footnoteFont)
                        .foregroundStyle(Color.hqLabel2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Restart Gateway…") { model.askRestart() }
                    .hqMacBordered()   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac push button
                    .fixedSize()       // [mac] Mac polish 2026-11-06 #105: one line, as every other button; the words wrap
                    .disabled(!model.canStartAction)
                    .accessibilityIdentifier("command-center.restart")
            }
        } else if model.restart.phase == .idle {
            Button { model.askRestart() } label: {
                HStack(spacing: 12) {
                    MaintenanceMark(symbol: "arrow.clockwise")
                    Text("Restart Gateway").foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
                .disabled(!model.canStartAction)
                .accessibilityIdentifier("command-center.restart")
        } else {
            HStack(alignment: .top, spacing: 12) {
                // [status-tidy] The busy row keeps its mark, as the rows around it.
                if !DeviceWord.isMac { MaintenanceMark(symbol: "arrow.clockwise") }
                VStack(alignment: .leading, spacing: 8) {
                    if model.restart.isBusy {
                        Text("Restart Gateway").foregroundStyle(Color.hqLabel2)
                    } else {
                        Button("Restart Gateway") { model.askRestart() }
                            .disabled(!model.canStartAction)
                            .accessibilityIdentifier("command-center.restart")
                    }
                    GatewayRestartProgress(run: model.restart)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func updateSection(_ status: GatewayStatusReport) -> some View {
        Section {
            updateRows
        } header: { HQSectionLabel {
            Text("Hermes")
        } } footer: { HQSectionFooter {
            if let message = updateFootnote { Text(message) }
        } }
        .onChange(of: model.updateRun?.end) { _, end in if end != nil { model.updateEnded() } }
    }

    /// Under the update's rows: why this gateway can't apply the update itself.
    var updateFootnote: String? {
        guard let check = model.update, !check.canUpdateNow || model.readOnly, check.behind != 0, model.updateRun == nil else { return nil }
        return check.message
    }

    @ViewBuilder var updateRows: some View {
        let check = model.update
        // [update-flow] An update shows whenever one is out: the sheet says when this gateway can't apply it itself
        // (and what to run instead), rather than the row hiding the button.
        let canUpdate = !model.readOnly && check?.updateAvailable == true
        Group {
            let recheck = (check == nil || check?.couldNotCheck == true) && model.updateChecked
            if let run = model.updateRun {
                // [update-flow] "Updating Studio…" and the step under way; a tap brings the same sheet back.
                HStack(spacing: 12) {
                    if !DeviceWord.isMac { MaintenanceMark(symbol: "arrow.up.circle", tint: true) }   // [status-tidy]
                    HermesUpdateRow(run: run)
                }
            } else if canUpdate {
                Button { model.askUpdate() } label: { updateLabel(check, tint: true) }
                    .disabled(!model.canStartAction)
                    .accessibilityIdentifier("command-center.update")
            } else if DeviceWord.isMac, recheck {
                // [mac] Stress test 2026-10-28 round 6: Check Again was a bare blue text row of its own under the status
                // it rechecks. On the Mac it is a push button at the trailing end of that status's row.
                HStack(spacing: 12) {
                    updateLabel(check, tint: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("command-center.update")
                    // [mac] Stress test 2026-10-28 round 7: `.bordered` is the system's tinted capsule on iOS 26 and on the
                    // Mac too, in both looks; the shared push button, as Restart Gateway… above it.
                    Button("Check Again") { model.retryUpdateCheck() }
                        .hqMacPushOnly()
                        .disabled(!model.online)
                        .accessibilityIdentifier("command-center.update.retry")
                }
            } else {
                updateLabel(check, tint: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("command-center.update")
            }
            // Stress test 2026-10-28 #20 follow-up: a gateway answer whose check couldn't run ("behind": null) also
            // reads "Couldn’t Check", so it offers Check Again too; before, only a missing answer did.
            if recheck, !DeviceWord.isMac, model.updateRun == nil {
                Button("Check Again") { model.retryUpdateCheck() }
                    .disabled(!model.online)
                    .accessibilityIdentifier("command-center.update.retry")
            }
        }
    }

    /// [update-flow] "0.23.0 Available · 3 Updates" when the check names the release.
    static func updateWords(_ check: HermesUpdateCheck) -> String {
        guard check.updateAvailable, let to = check.sourceVersion ?? check.rollbackTo else { return check.words }
        let release = "\(HermesUpdateEnd.normalized(to)) Available"
        guard let behind = check.behind, behind > 0 else { return release }
        return release + " · " + (behind == 1 ? "1 change" : "\(behind) changes")
    }

    private func updateLabel(_ check: HermesUpdateCheck?, tint: Bool) -> some View {
        HStack(spacing: 12) {
            if !DeviceWord.isMac { MaintenanceMark(symbol: "arrow.up.circle", tint: tint) }
            VStack(alignment: .leading, spacing: 3) {
                Text("Update Hermes")
                    .foregroundStyle(tint ? Color.hqTint : Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.map(Self.updateWords) ?? (model.updateChecked ? "Couldn’t Check" : "Checking…"))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Maintenance

/// [status-page] The page's second part, under the status (it was the Maintenance tab).
struct CommandCenterMaintenance: View {
    @Bindable var model: CommandCenterModel

    var body: some View {
        // [status-tidy] On the iPhone and iPad: Restart Gateway and Update Hermes lead this list and Recent Logs ends
        // it, every row with a mark, the names in the label's colour (they stood in three boxes in three styles: a
        // grey title, a blue link, a blue title over small print).
        let oneList = CommandCenterSystem.oneList(model) && model.status != nil
        let system = CommandCenterSystem(model: model)
        Section {
            if oneList {
                system.restartRow
                system.updateRows
            }
            ForEach(MaintenanceAction.allCases) { action in
                Button { model.run(action) } label: {
                    HStack(spacing: 12) {
                        if !DeviceWord.isMac { MaintenanceMark(symbol: action.symbol) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.title).foregroundStyle(DeviceWord.isMac ? Color.hqTint : Color.hqLabel)
                            Text(action.detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.maintenance.isBusy, model.maintenanceAction == action { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, DeviceWord.isMac ? 12 : 6)
                    .contentShape(Rectangle())
                }
                .disabled(!model.canStartMaintenance)
                .accessibilityIdentifier("command-center.maintenance.\(action.rawValue)")
            }
            if oneList {
                Button { model.openLogs() } label: {
                    HStack(spacing: 12) {
                        MaintenanceMark(symbol: "doc.text")
                        Text("Recent Logs").foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 0)
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("command-center.logs")
            }
        } header: { HQSectionLabel {
            Text("Maintenance")   // [status-page] the page's own word for its second part (was "Diagnostics" on its tab)
        } } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 6) {
                if oneList, let message = system.updateFootnote { Text(message) }
                if !model.online { Text(MorePages.offlineFooter) } else { Text("These run on \(HostWord.phrase). Nothing is sent anywhere else.") }
            }
        } }
        .onChange(of: model.updateRun?.end) { _, end in if oneList, end != nil { model.updateEnded() } }
        if let action = model.maintenanceAction, let words = ActionWords.maintenance(model.maintenance.phase) {
            Section {
                NavRow(title: "\(action.outputTitle) Output", value: words.isError && !words.isBusy && model.maintenance.lines.isEmpty ? "Failed" : (words.text.count <= 24 ? words.text : nil)) {
                    model.openMaintenanceOutput()
                }
                .accessibilityIdentifier("command-center.maintenance.output")
            }
        }
    }
}


/// [status-tidy] A maintenance row's mark: the symbol on a quiet 28 pt tile, as More's rows have theirs.
struct MaintenanceMark: View {
    var symbol: String
    var tint = false

    var body: some View {
        Image(systemName: symbol)
            .font(Font.hq(.subheadline).weight(.medium))
            .foregroundStyle(tint ? Color.hqTint : Color.hqLabel2)
            .frame(width: HQFont.scaled(28), height: HQFont.scaled(28))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.hqFill3))
            .accessibilityHidden(true)
    }
}

extension MaintenanceAction {
    var symbol: String {
        switch self { case .doctor: "stethoscope"; case .securityAudit: "lock.shield"; case .backup: "externaldrive" }
    }
}
