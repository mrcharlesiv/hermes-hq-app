// ⋯ › Usage & Limits: what is left on each signed-in plan (a bar per allowance, when it fills again, a rate limit),
// each pay-as-you-go login's balance where Hermes gives one, the plan credits Hermes reports, this chat's tokens and
// cost, and the gateway's whole /usage report. The rows are HermesKit's (`UsageLimitsModel`); this is the sheet.
// Owner 2026-10-30 ("a better design and better functionality"): the chat's tightest allowance leads in a card with a
// ring; bars colour by what is left, mark where an even pace would be and say when one runs out early; reset times on
// the clock too; a bell reminds when an allowance fills again; the page re-reads itself and says how old it is.

import SwiftUI
import UIKit
import UserNotifications

@MainActor
enum UsageLimitsSheet {
    static func make(context: ModelMenuContext, chat: LiveChatSession) -> UINavigationController {
        let model = UsageLimitsPageModel(context: context, chat: chat)
        let page = MorePageController(title: "Usage & Limits", identifier: "usage.page", UsageLimitsView(model: model))
        model.host = page
        page.retained = [model]
        page.onAppear = { [weak model] in model?.appear() }
        page.keyRefresh = { [weak model] in Task { await model?.reload() } }   // ⌘R, as a pull
        return ChatSheet.wrap(page, title: "Usage & Limits", detents: [.large()])
    }
}

@MainActor @Observable
final class UsageLimitsPageModel {
    enum Load: Equatable { case loading, ready, failed(String) }

    @ObservationIgnored let context: ModelMenuContext
    @ObservationIgnored weak var chat: LiveChatSession?
    @ObservationIgnored weak var host: UIViewController?

    private(set) var load: Load = .loading
    private(set) var blocks: [UsageBlock] = []
    /// [tester batch 3] The pay-as-you-go logins and their balances.
    private(set) var balances: [UsageBalanceRow] = []
    /// [tester batch 3] The chat provider's balance under its plan's bars (an OpenRouter key with a limit, Codex), by block.
    private(set) var blockBalances: [String: UsageBalance] = [:]
    private(set) var chatRows: [UsageChatRow] = []
    private(set) var credits: [String] = []
    private(set) var reportBusy = false
    /// When the catalog was last read (the bar's "Updated 4 min ago").
    private(set) var updatedAt: Date?
    /// The allowances with a reset reminder set, by gauge id.
    private(set) var reminders: Set<String> = []
    /// What "resets in" and the pace count from: moves on with the page's minute tick.
    private(set) var now = Date()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var askedAgain = false
    /// This chat's /usage figures (OpenRouter's and Codex's balance for its own provider, Nous's for any) and
    /// billing.state.
    @ObservationIgnored private var report: UsageRead<[String: UsageBalance]> = .notAsked
    @ObservationIgnored private var billing: UsageRead<JSONValue> = .notAsked
    /// The /usage reads sent, and the newest whose answer is in: a pull, Try Again and the full report can overlap, and
    /// their answers land in any order.
    @ObservationIgnored private var reportsAsked = 0
    @ObservationIgnored private var reportHeard = 0
    /// The same for billing.state, whose every answer is the whole state: the newest answered wins.
    @ObservationIgnored private var billingAsked = 0
    @ObservationIgnored private var billingHeard = 0

    init(context: ModelMenuContext, chat: LiveChatSession) {
        self.context = context
        self.chat = chat
        // A cached catalog paints at once; the read below replaces it.
        if let options = context.options { apply(options) }
        chatRows = shownChatRows()
    }

    /// This chat's rows, the Cost row with the model's price as ⋯ › Model Prices words it.
    private func shownChatRows() -> [UsageChatRow] {
        let current = context.current()
        let price = ModelPricesModel.menuSubtitle(context.options, model: current.id, provider: current.provider,
                                                  fallback: ModelsDevCache.shared.stored())
        return UsageLimitsModel.chatRows(chat?.shownUsage, price: price).map(UsageChatRow.init)
    }

    func appear() {
        showFreshness()
        Task { reminders = await UsageReminders.pending() }
        guard !started else { return }
        started = true
        Task { await reload() }
    }

    func reload() async {
        async let catalog: Void = readCatalog()
        async let chat: Void = readChat()
        async let balances: Void = readBalances()
        _ = await (catalog, chat, balances)
    }

    private func readCatalog() async {
        do {
            _ = try await context.load(reread: true)
            guard let options = context.options else { return }
            updatedAt = Date()
            apply(options)
            load = .ready
            // The gateway asks the providers in the background after a read: once, a moment later, what it learned.
            if !askedAgain, UsageLimitsModel.worthAskingAgain(options) {
                askedAgain = true
                try? await Task.sleep(for: .seconds(4))
                if (try? await context.load(reread: true)) != nil, let fresh = context.options { updatedAt = Date(); apply(fresh) }
            }
        } catch {
            if context.options == nil { load = .failed(MenusError.text(error)) } else { load = .ready }
        }
    }

    private func readChat() async {
        guard let chat, chat.runtimeSessionId != nil else { return }
        if let answer = try? await chat.sessionCall("session.usage", timeout: .seconds(5), runtime: .required, params: { _ in [:] }) {
            if let usage = SessionUsage.decode(answer["usage"] ?? answer) { chat.menus.usage = usage }
            credits = UsageLimitsModel.creditLines(answer)
        }
        // No context in the report yet (a chat not run in this gateway process): the gateway's estimate, marked "~".
        await chat.refreshContextEstimate()
        chatRows = shownChatRows()
    }

    /// [tester batch 3] The balances Hermes can give, both reads at once. Offline nothing is sent: what was read stays,
    /// what wasn't says Offline.
    private func readBalances() async {
        guard let chat else { return }
        guard !context.offline else { applyBalances(); return }
        async let report: Void = readReport(chat)
        async let billing: Void = readBilling(chat)
        _ = await (report, billing)
    }

    /// /usage, answered live from this chat (H:tui_gateway/methods_slash.py `_format_live_usage_output`). It needs a
    /// running chat: asking one that hasn't started would start it, so it isn't asked.
    private func readReport(_ chat: LiveChatSession) async {
        // A re-read keeps what it has: while it asks, and in a chat whose runtime has gone since.
        guard chat.runtimeSessionId != nil else {
            if case .done = report {} else { report = .notAsked }
            applyBalances(); return
        }
        if case .done = report {} else { report = .pending }
        applyBalances()
        reportsAsked += 1
        let asked = reportsAsked
        do {
            let result = try await chat.sessionCall("slash.exec", timeout: .seconds(45), runtime: .required) { _ in
                ["command": .string("usage")]
            }
            heard(asked, result["output"]?.string ?? "")
        } catch {
            unheard(asked, MenusError.text(error))
        }
        applyBalances()
    }

    /// Read `asked`'s answer: its figures join the page's, a newer read's winning.
    private func heard(_ asked: Int, _ text: String) {
        report = UsageLimitsModel.joined(report, UsageLimitsModel.reportedBalances(text), newer: asked > reportHeard)
        reportHeard = max(reportHeard, asked)
    }

    /// Read `asked` failed: said only when it is the newest read sent and none has been answered.
    private func unheard(_ asked: Int, _ why: String) {
        guard asked == reportsAsked else { return }
        if case .done = report {} else { report = .failed(why) }
    }

    /// billing.state: Nous's balance with its states (free tier, signed out, the portal failing). It reads the gateway's
    /// own Nous login whichever bot asks, so only the main bot's chats ask it, and only while Nous may be signed in.
    private func readBilling(_ chat: LiveChatSession) async {
        let main = chat.profile.isEmpty || chat.profile == "default"
        let nous = context.options.map { $0.providers.contains { $0.slug == UsageLimitsModel.nous && $0.authenticated != false } } ?? true
        guard main, nous else { return }
        if case .done = billing {} else { billing = .pending }
        applyBalances()
        billingAsked += 1
        let asked = billingAsked
        do {
            var params: [String: JSONValue] = [:]
            if let profile = chat.profileParam { params["profile"] = .string(profile) }
            // Not sessionCall: billing.state takes `profile` only (ProfileParams), a session id is refused.
            let state = try await chat.client.call("billing.state", .object(params), timeout: .seconds(20))
            if asked > billingHeard { billing = .done(state); billingHeard = asked }
        } catch {
            if asked == billingAsked, billingHeard == 0 { billing = .failed(MenusError.text(error)) }
        }
        applyBalances()
    }

    func retryBalances() {
        Task { await readBalances() }
    }

    private func applyBalances() {
        blockBalances = Dictionary(blocks.compactMap { block in
            UsageLimitsModel.blockBalance(block, report: report).map { (block.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        guard let options = context.options else { balances = []; return }
        balances = UsageLimitsModel.balanceRows(options, blocks: blocks, currentProvider: context.current().provider,
                                                report: report, billing: billing, offline: context.offline)
    }

    /// [tester batch 3] While the page shows, the balances follow the connection (the Models sheet's watch): when it
    /// goes, a row a read would fill says Offline and the figures stay; when it comes back, those rows are read again.
    func followConnection() async {
        var offline = context.offline
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, context.offline != offline else { continue }
            offline = context.offline
            if offline { applyBalances() } else if balances.contains(where: { $0.balance == .offline }) { await readBalances() }
        }
    }

    /// While the page shows: "resets in" counts down, a window whose time comes shows refilled, and every few minutes
    /// the catalog is read again (the gateway keeps asking the providers), so a page left open stays true.
    func tick() async {
        var minutes = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            minutes += 1
            if minutes % Self.rereadMinutes == 0, !context.offline, load != .loading { await readCatalog() }
            else if let options = context.options { apply(options) }
        }
    }

    static let rereadMinutes = 3

    private func apply(_ options: ModelOptions) {
        let current = context.current()
        now = Date()
        blocks = UsageLimitsModel.blocks(options, currentProvider: current.provider, now: now)
        applyBalances()
        showFreshness()
    }

    /// "Updated 4 min ago" under the sheet's title.
    func showFreshness() {
        let words = UsageLimitsModel.freshness(updatedAt, now: Date(), offline: context.offline)
        guard let host, host.navigationItem.subtitle != words else { return }
        host.navigationItem.subtitle = words
    }

    // MARK: Reminders

    /// A bell on an allowance: a notification when it fills again, or none if one was set.
    func toggleReminder(_ gauge: UsageGauge, in block: UsageBlock) {
        Task {
            if reminders.contains(gauge.id) {
                UsageReminders.cancel(gauge.id)
                reminders.remove(gauge.id)
                Haptics.play(.light)
                return
            }
            guard let at = gauge.resetsAt, at > Date() else { return }
            let name = [block.title, block.account].compactMap { $0 }.joined(separator: " · ")
            switch await UsageReminders.schedule(id: gauge.id, at: at, title: "\(gauge.title) Has Reset",
                                                 body: "\(name): your \(gauge.title.lowercased()) allowance is full again.") {
            case .set:
                reminders.insert(gauge.id)
                Haptics.play(.success)
            case .denied:
                presentDenied()
            case .failed(let why):
                // iOS's own words are a system error's, not a reason: they stay behind Show Details (audit 10-4).
                FailureAlert.present(title: "Couldn’t Set the Reminder", reason: "\(DeviceWord.system) didn’t set the reminder. Try again in a moment.",
                                     detail: why, from: host)
            }
        }
    }

    private func presentDenied() {
        guard let host else { return }
        Haptics.play(.warning)
        // [mac] Mac polish #11: on the Mac, System Settings › Notifications (`PrivacySettingsLink`).
        let alert = UIAlertController(title: "Notifications Are Off",
                                      message: "Allow notifications for Hermes HQ in \(PrivacySettingsLink.place) to be reminded when an allowance resets.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: PrivacySettingsLink.openTitle, style: .default) { _ in PrivacySettingsLink.open(.notifications) })
        (host.presentedViewController ?? host).present(alert, animated: true)
    }

    func retry() {
        load = .loading
        Task { await reload() }
    }

    /// The gateway's own /usage (it asks the chat's provider live): its text on a page of its own.
    func openReport() {
        guard !reportBusy, let chat else { return }
        reportBusy = true
        reportsAsked += 1
        let asked = reportsAsked
        Task {
            defer { reportBusy = false }
            do {
                let result = try await chat.sessionCall("slash.exec", timeout: .seconds(60), runtime: .resumeFirst) { _ in
                    ["command": .string("usage")]
                }
                let text = result["output"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "No report."
                // A /usage like the balances' own: they take it too.
                heard(asked, result["output"]?.string ?? "")
                applyBalances()
                let page = ChatBlocksViewController(heading: nil, blocks: [ChatBlocksViewController.Block(label: "/usage", text: text)])
                page.title = "Usage Report"
                host?.navigationController?.pushViewController(page, animated: true)
            } catch {
                unheard(asked, MenusError.text(error))
                applyBalances()
                Haptics.play(.error)
                FailureAlert.present(title: "Couldn’t Get the Report", reason: MenusError.text(error), from: host)
            }
        }
    }
}

struct UsageChatRow: Identifiable, Hashable {
    var label: String
    var value: String
    var note: String?
    var bar: Double?
    var id: String { label }

    init(_ row: SessionInfoRow) {
        label = row.label; value = row.value; note = row.note; bar = row.bar
    }
}

/// Local notifications for "remind me when it resets": one per allowance, by its gauge id.
enum UsageReminders {
    enum Outcome { case set, denied, failed(String) }
    static let prefix = "usage-reset."

    static func schedule(id: String, at date: Date, title: String, body: String) async -> Outcome {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else { return .denied }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": "usage.reset"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: trigger))
            AppLog.note("usage", "reset reminder set")
            return .set
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prefix + id])
    }

    /// The gauge ids with a reminder still waiting.
    static func pending() async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
}

struct UsageLimitsView: View {
    @Bindable var model: UsageLimitsPageModel
    @State private var quietOpen = false

    var body: some View {
        List {
            if let lead = UsageLimitsModel.headline(model.blocks) {
                Section {
                    UsageHeadlineCard(block: lead.block, gauge: lead.gauge, now: model.now)
                } header: { HQSectionLabel { Text("At a Glance") } }
            }
            limits
            if !model.credits.isEmpty {
                Section {
                    ForEach(model.credits, id: \.self) { line in
                        Text(line).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                    }
                } header: { HQSectionLabel { Text("Credits") } }
            }
            if !model.chatRows.isEmpty {
                Section {
                    ForEach(model.chatRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(row.value).foregroundStyle(Color.hqLabel).monospacedDigit()
                                    if let note = row.note {
                                        Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            } label: {
                                Text(row.label).foregroundStyle(Color.hqLabel)
                            }
                            if let bar = row.bar {
                                UsageBar(left: bar, tint: Color.hqTint)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("usage.chat.\(row.label.lowercased())")
                    }
                } header: { HQSectionLabel { Text("This Chat") } }
            }
            // Only logins with no balance: one folded row at the foot of the page, under what has numbers.
            if shownBalances.isEmpty, !quietBalances.isEmpty { balanceSection }
            Section {
                Button {
                    model.openReport()
                } label: {
                    HStack {
                        // [mac] Stress test 2026-10-28 #75: a plain action row on the Mac; the leading icon was a
                        // style no other row in these sheets uses.
                        if DeviceWord.isMac {
                            Text("Full Usage Report").foregroundStyle(Color.hqTint)
                        } else {
                            Label("Full Usage Report", systemImage: "doc.text.magnifyingglass").foregroundStyle(Color.hqTint)
                        }
                        Spacer()
                        if model.reportBusy { ProgressView().controlSize(.small) }
                    }
                }
                .accessibilityIdentifier("usage.report")
            } footer: { HQSectionFooter {
                Text("Hermes’s full usage report for this chat, asked live from its provider.")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            } }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        // The rows without a font of their own (This Chat, Pay As You Go, the bars' names) take the look's body: in
        // Desktop Look they drew at the system's 17 pt beside the look's smaller Credits lines.
        .font(Font.hq(.body))
        .refreshable { await model.reload() }
        .task { await model.tick() }
        .task { await model.followConnection() }
        .accessibilityIdentifier("usage.list")
    }

    @ViewBuilder private var limits: some View {
        if balancesFirst { balanceSection }
        if model.blocks.isEmpty {
            switch model.load {
            case .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking your plans…").foregroundStyle(Color.hqLabel2)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("usage.loading")
                }
            case .failed(let reason):
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn’t read your plans.").foregroundStyle(Color.hqLabel)
                        Text(reason).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { model.retry() }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("usage.failed")
                }
            case .ready:
                if DeviceWord.isMac {
                    // [mac] Stress test 2026-10-28 #75: a note under a Plan Limits header, not a boxed row that reads
                    // as a value with no name.
                    Section {
                    } header: { HQSectionLabel { Text("Plan Limits") } } footer: { HQSectionFooter {
                        Text("None of your signed-in providers report a plan limit.")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("usage.none")
                    } }
                } else {
                    Section {
                        Text("None of your signed-in providers report a plan limit.")
                            .foregroundStyle(Color.hqLabel2)
                            .accessibilityIdentifier("usage.none")
                    }
                }
            }
        }
        ForEach(model.blocks) { block in
            Section {
                ForEach(block.gauges) { gauge in
                    UsageGaugeRow(gauge: gauge, now: model.now, reminder: model.reminders.contains(gauge.id)) {
                        model.toggleReminder(gauge, in: block)
                    }
                }
                if let balance = model.blockBalances[block.id] {
                    UsageBalanceRowView(row: UsageBalanceRow(provider: block.provider, title: UsageLimitsModel.blockBalanceTitle,
                                                             current: false, balance: balance))
                }
                ForEach(block.notes, id: \.self) { note in UsageNoteRow(note: note) }
            } header: {
                HQSectionLabel {
                    HStack(spacing: 8) {
                        Text([block.title, block.account].compactMap { $0 }.joined(separator: " · "))
                        if block.current { UsageThisChatBadge() }
                    }
                    // Read as one line, as it was written before the badge: "OpenRouter · This Chat".
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([block.title, block.account, block.current ? "This Chat" : nil].compactMap { $0 }.joined(separator: " · "))
                }
                // [tester batch 3] On the header only: on the Section it reached every row and hid each one's own (the
                // gauges', the Credits balance row's).
                .accessibilityIdentifier("usage.block.\(block.provider)")
            }
        }
        if !balancesFirst, !shownBalances.isEmpty { balanceSection }
    }

    /// The chat's own provider first: when it pays as it goes and has a balance to show, that leads the page.
    private var balancesFirst: Bool { shownBalances.first?.current == true }

    private var shownBalances: [UsageBalanceRow] { model.balances.filter { !$0.quiet } }
    private var quietBalances: [UsageBalanceRow] { model.balances.filter(\.quiet) }

    /// [mac-audit] Owner 2026-11-02 (#23): "No Balance Reported 1 ›" read as a count of balances. The fold's row says it
    /// plainly and names whose ("Balance not reported" over "OpenRouter"); the fold still opens to each one's note.
    private var quietLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Balance not reported").foregroundStyle(Color.hqLabel)
            if !quietOpen {   // open, the rows under it name them
                Text(quietBalances.map(\.title).formatted(.list(type: .and)))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
        }
        // On the label: on the group it reached the rows inside and hid each one's own.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.balances.quiet")
    }

    /// [tester batch 3] Each pay-as-you-go login and its balance, as Hermes reports it; those with none folded under one
    /// row (owner, 2026-10-30: ten "Balance not available" rows buried the page).
    @ViewBuilder private var balanceSection: some View {
        if !model.balances.isEmpty {
            Section {
                ForEach(shownBalances) { row in UsageBalanceRowView(row: row) }
                if !quietBalances.isEmpty {
                    if DeviceWord.isMac {
                        // [mac] Mac polish #126: the fold's › is the Mac's quiet chevron (`MacChevron`, as every other
                        // Mac row has), turned down while open; DisclosureGroup's own arrow was full black (white in the
                        // Desktop Look) and larger, whatever its tint. The rows under it are the list's own, as before.
                        Button {
                            withAnimation(HQMotion.swiftUI(.smooth(duration: 0.25))) { quietOpen.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                quietLabel.frame(maxWidth: .infinity, alignment: .leading)
                                MacChevron().rotationEffect(.degrees(quietOpen ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityValue(quietOpen ? "Expanded" : "Collapsed")
                        if quietOpen { ForEach(quietBalances) { row in UsageQuietBalanceRow(row: row) } }
                    } else {
                        DisclosureGroup(isExpanded: $quietOpen) {
                            ForEach(quietBalances) { row in UsageQuietBalanceRow(row: row) }
                        } label: { quietLabel }
                        .tint(Color.hqLabel2)
                    }
                }
                if model.balances.contains(where: { if case .failed = $0.balance { true } else { false } }) {
                    Button("Check Again") { model.retryBalances() }
                        .foregroundStyle(Color.hqTint)
                        .accessibilityIdentifier("usage.balances.retry")
                }
            } header: {
                HQSectionLabel { Text("Pay As You Go") }
            } footer: { HQSectionFooter {
                Text(UsageLimitsModel.balanceFooter)
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("usage.balances.footer")
            } }
        }
    }
}

/// [tester batch 3] One pay-as-you-go login: its name, its balance as Hermes gives it (or why there is none), and a
/// note under the name. At the largest text sizes the balance goes under the name.
struct UsageBalanceRowView: View {
    var row: UsageBalanceRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Beside the name the value sits on its first line. A spinner has no text baseline (it pushed "Checking…" below
        // the name), so that row is centred instead: it has no note, so its name is one line.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: row.balance == .checking ? .center : .firstTextBaseline, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).foregroundStyle(Color.hqLabel)
                if let note = row.note {
                    Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            // The value keeps its line and the name and note wrap first ("Balance not available" beside a note broke
            // in two).
            HStack(spacing: 6) {
                if row.balance == .checking { ProgressView().controlSize(.small) }
                Text(row.value(money: { BillingText.money($0) }))
                    .foregroundStyle(amount ? Color.hqLabel : Color.hqLabel2)
                    .monospacedDigit()
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.balance.\(row.provider)")
    }

    private var amount: Bool {
        switch row.balance {
        case .amount, .unlimited: true
        default: false
        }
    }
}

/// A login under Balance not reported: its name, and where its balance shows instead when Hermes can give one.
struct UsageQuietBalanceRow: View {
    var row: UsageBalanceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label).foregroundStyle(Color.hqLabel2)
            if let note = row.note {
                Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.balance.\(row.provider)")
    }
}

/// What is left decides an allowance's colour: the tint, orange under a quarter, red under a tenth.
private func usageColor(_ left: Double) -> Color {
    left < 0.1 ? Color.hqRed : left < 0.25 ? Color.hqOrange : Color.hqTint
}

/// "Resets in 3h 24m · 4:10 PM"
private func resetLine(_ gauge: UsageGauge, now: Date) -> String? {
    guard let reset = gauge.reset else { return nil }
    let said = reset.prefix(1).uppercased() + reset.dropFirst()
    guard let at = gauge.resetsAt, at > now else { return said }
    return "\(said) · \(UsageLimitsModel.clock(at, now: now))"
}

/// The pace line: orange when the allowance runs out before it resets, red once it has.
private struct UsagePaceLabel: View {
    var pace: UsagePace

    var body: some View {
        switch pace {
        case .steady:
            Label(pace.text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.hqLabel2)
                .labelStyle(UsageIconLabelStyle(icon: Color.hqTint))
        case .runsOut:
            Label(pace.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.hqOrange)
                .labelStyle(UsageIconLabelStyle(icon: Color.hqOrange))
        case .usedUp:
            Label(pace.text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Color.hqRed)
                .labelStyle(UsageIconLabelStyle(icon: Color.hqRed))
        }
    }
}

private struct UsageIconLabelStyle: LabelStyle {
    var icon: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.foregroundStyle(icon).imageScale(.small)
            configuration.title
        }
    }
}

/// An allowance's bar: what is left, from the leading edge, with a tick where an even pace would have it.
struct UsageBar: View {
    var left: Double
    var elapsed: Double?
    var height: CGFloat = 8
    /// A bar that isn't an allowance (the chat's context) keeps one colour.
    var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hqFill3)
                Capsule().fill(tint ?? usageColor(left))
                    .frame(width: left > 0 ? max(height, width * left) : 0)
                if let elapsed, elapsed > 0.02, elapsed < 0.98 {
                    // An even pace leaves 1 − elapsed: a bar short of the tick is ahead of it.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.hqLabel2)
                        .frame(width: 2, height: height + 6)
                        .offset(x: width * (1 - elapsed) - 1)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
    }
}

/// A small tinted capsule beside a block's name: this chat's provider.
struct UsageThisChatBadge: View {
    var body: some View {
        Text("This Chat")
            .font(Font.hq(.caption2).weight(.semibold))
            .textCase(nil)
            .tracking(0)   // Desktop Look's headers are letter-spaced capitals; the badge stays a word
            .foregroundStyle(Color.hqTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.hqTint.opacity(0.14)))
    }
}

/// What a bar can't say. A rate limit or a used-up login warns; "Signed out", "Not reported yet", "Refilled" don't.
struct UsageNoteRow: View {
    var note: String

    var body: some View {
        let warns = note.hasPrefix("Used up") || note.localizedCaseInsensitiveContains("rate limited")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: warns ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(warns ? Color.hqOrange : Color.hqLabel2)
                .imageScale(.small)
            Text(note).font(Font.hq(.subheadline)).foregroundStyle(warns ? Color.hqLabel : Color.hqLabel2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The page's lead: the chat's tightest allowance as a ring, when it fills again, and whether it lasts till then.
struct UsageHeadlineCard: View {
    var block: UsageBlock
    var gauge: UsageGauge
    var now: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            ring
            VStack(alignment: .leading, spacing: 3) {
                Text([block.title, block.account].compactMap { $0 }.joined(separator: " · "))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                Text(gauge.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                if let reset = resetLine(gauge, now: now) {
                    Text(reset).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).monospacedDigit()
                }
                if let pace = gauge.pace {
                    UsagePaceLabel(pace: pace).font(Font.hq(.footnote)).padding(.top, 2)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), \(gauge.title)")
        .accessibilityValue([gauge.detail, gauge.pace?.text].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("usage.headline")
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.hqFill3, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.001, gauge.left))
                .stroke(usageColor(gauge.left), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text(UsageLimitsModel.percent(gauge.left))
                    .font(Font.hq(.title3).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Color.hqLabel)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("left").font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 76, height: 76)
        .animation(HQMotion.reduced ? nil : .smooth(duration: 0.35), value: gauge.left)
    }
}

/// One allowance: its name and what is left, a bar that empties as it is used (a tick where an even pace would be),
/// when it fills again on the clock, a warning when it runs out early, and a bell to be told when it is full again.
struct UsageGaugeRow: View {
    var gauge: UsageGauge
    var now: Date = Date()
    var reminder = false
    var toggleReminder: (() -> Void)?

    /// The bell shows where it helps: an allowance running low, used up or running out early, or one already set.
    private var offersReminder: Bool {
        guard let at = gauge.resetsAt, at > now, toggleReminder != nil else { return false }
        if reminder || gauge.warning { return true }
        if case .runsOut = gauge.pace { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.title).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text(gauge.leftText)
                    .font(Font.hq(.body).weight(.semibold))
                    .foregroundStyle(gauge.warning ? usageColor(gauge.left) : Color.hqLabel)
                    .monospacedDigit()
            }
            UsageBar(left: gauge.left, elapsed: gauge.elapsed)
                .animation(HQMotion.reduced ? nil : .smooth(duration: 0.35), value: gauge.left)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let reset = resetLine(gauge, now: now) {
                        Text(reset).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).monospacedDigit()
                    }
                    if let pace = gauge.pace, pace != .steady {
                        UsagePaceLabel(pace: pace).font(Font.hq(.footnote))
                    }
                }
                Spacer(minLength: 0)
                if offersReminder, let toggleReminder {
                    Button(action: toggleReminder) {
                        Image(systemName: reminder ? "bell.fill" : "bell")
                            .font(Font.hq(.body))
                            .foregroundStyle(reminder ? Color.hqTint : Color.hqLabel2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, -12)   // a 44 pt target that doesn't grow the row
                    .accessibilityLabel(reminder ? "Cancel Reset Reminder" : "Remind Me When It Resets")
                    .help(reminder ? "Cancel Reset Reminder" : "Remind Me When It Resets")   // [mac] the pointer's tip
                    .accessibilityIdentifier("usage.remind.\(gauge.id)")
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if let at = gauge.resetsAt, at > now, let toggleReminder {
                Button(action: toggleReminder) {
                    Label(reminder ? "Cancel Reset Reminder" : "Remind Me When It Resets",
                          systemImage: reminder ? "bell.slash" : "bell")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gauge.title)
        .accessibilityValue([gauge.detail, gauge.pace.flatMap { $0 == .steady ? nil : $0.text }, reminder ? "Reminder set" : nil]
            .compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("usage.gauge.\(gauge.id)")
    }
}
