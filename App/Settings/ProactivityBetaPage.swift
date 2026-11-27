// [proactivity-beta] Settings › Proactivity (Beta): install, toggle (off by default), tune autonomy mode,
// and open the full Proactivity (Beta) Plugin Page for any bot profile.

import Observation
import SwiftUI
import UIKit

@MainActor
enum ProactivityBetaPage {
    static let title = ProactivityBeta.pageLabel

    static func make(router: SettingsRouter) -> UIViewController {
        let model = ProactivityBetaModel(services: router.services)
        let page = SettingsPageController(title: title, ProactivityBetaView(model: model, router: router))
        page.view.accessibilityIdentifier = "settings.proactivity-beta-page"
        page.view.backgroundColor = HQPalette.page
        return page
    }
}

@MainActor @Observable
final class ProactivityBetaModel {
    enum Phase: Equatable {
        case loading
        case notInstalled
        case needsRestart
        case ready(ProactivityBeta.Status)
        case failed(String)
    }

    var profile: String
    var phase: Phase = .loading
    var busy = false
    var notice: String?
    var error: String?

    @ObservationIgnored let services: any AppServices
    @ObservationIgnored var dashboardPage: PluginDashboardPage?

    init(services: any AppServices) {
        self.services = services
        let bots = services.bots.filter { !$0.hidden }
        self.profile = bots.first(where: { $0.id == "default" })?.id ?? bots.first?.id ?? "default"
    }

    var botChoices: [(id: String, name: String)] {
        let visible = services.bots.filter { !$0.hidden }.map { ($0.id, $0.name) }
        return visible.isEmpty ? [("default", "Hermes")] : visible
    }

    var botName: String {
        botChoices.first { $0.id == profile }?.name ?? DisplayName.title(profile)
    }

    private var capabilities: CapabilitiesStore? {
        (services as? SettingsServices)?.capabilities as? CapabilitiesStore
    }

    var client: (any GatewayClient)? {
        capabilities?.client ?? (services as? AppModel)?.client
    }

    var canAskRestart: Bool {
        guard let app = services as? AppModel else { return false }
        return !CloudGatewayFlow.isCloud(app.account?.baseURL) && (try? MainBotRequest.mainBot(app.bots)) != nil
    }

    func selectProfile(_ next: String) {
        guard next != profile else { return }
        profile = next
        dashboardPage = nil
        notice = nil
        error = nil
        Task { await refresh() }
    }

    func refresh() async {
        guard let client else {
            phase = .failed("Sign in to a gateway to manage Proactivity (Beta).")
            return
        }
        error = nil
        if case .loading = phase { } else { phase = .loading }

        // First probe the plugin's live status route directly.
        do {
            let status = try await ProactivityBetaAPI.status(client, profile: profile)
            phase = .ready(status)
            let pages = try? await DashboardPagesAPI.list(client, profile: profile)
            dashboardPage = pages?.first { $0.name == ProactivityBeta.pluginName }
            if let pages { PluginPagesMore.note(pages, profile: profile) }
            return
        } catch {
            if !ProactivityBetaAPI.isRouteMissing(error) {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn’t reach Hermes.")
                return
            }
        }

        // Route returned 404 Not Found: check whether the plugin is already installed (needs restart) or absent.
        if let capabilities {
            let installed = (try? await capabilities.plugins(profile)) ?? []
            if let found = installed.first(where: { $0.name == ProactivityBeta.pluginName || $0.catalogName == ProactivityBeta.pluginName }) {
                if !found.enabled {
                    _ = try? await capabilities.plugin(.toggle(key: found.key ?? found.name, enable: true), profile: profile)
                }
                phase = .needsRestart
                return
            }
        }
        phase = .notInstalled
    }

    func install() async {
        guard !busy else { return }
        guard let capabilities else {
            error = "This gateway doesn’t support plugin installation from the app."
            return
        }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            let result = try await capabilities.plugin(
                .install(identifier: ProactivityBeta.pluginSource, force: false, enable: true, ref: nil),
                profile: profile
            )
            if result.consentRequired {
                error = "Install requires confirmation in your Hermes terminal: hermes plugins install \(ProactivityBeta.pluginSource) --enable"
                return
            }
            if !result.ok && result.name == nil {
                error = result.warnings.first ?? "Couldn’t install Proactivity (Beta)."
                return
            }
            if let client {
                await DashboardPagesAPI.rescan(client, profile: profile)
            }
            notice = "Installed Proactivity (Beta) for \(botName). It starts off by default."
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn’t install Proactivity (Beta)."
        }
    }

    func update(_ fields: [String: JSONValue], note: String? = nil) async {
        guard !busy, let client else { return }
        let previous = phase
        busy = true
        error = nil
        defer { busy = false }
        do {
            let updated = try await ProactivityBetaAPI.patchSettings(client, profile: profile, fields: fields)
            phase = .ready(updated)
            if let note { notice = note }
        } catch {
            phase = previous
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn’t save Proactivity settings."
        }
    }

    func runSweep(forceBrief: Bool) async {
        guard !busy, let client else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            let out = try await ProactivityBetaAPI.runSweep(client, profile: profile, forceBrief: forceBrief)
            if out.quiet {
                notice = "Signal check quiet — nothing crossed threshold (0 tokens)."
            } else {
                notice = "Checked \(out.signalsDetected) signal(s), staged \(out.createdOffers) offer(s)."
            }
            let updated = try await ProactivityBetaAPI.status(client, profile: profile)
            phase = .ready(updated)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Signal check failed."
        }
    }

    func askToRestart() async {
        guard !busy, let app = services as? AppModel else { return }
        do {
            try app.canAskMainBot()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? MainBotRequest.couldNotSend
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        let prompt = PluginPageRestart.prompt(label: ProactivityBeta.pageLabel, plugin: ProactivityBeta.pluginName, bot: botName)
        do {
            try await MainBotRequest.queue(
                text: prompt,
                title: PluginPageRestart.title(page: ProactivityBeta.pageLabel),
                linkReady: { [weak app] in app?.connection == .ready }
            )
            notice = "Asked your main bot to restart Hermes. Tap Check Again once it reconnects."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? MainBotRequest.couldNotSend
        }
    }

    func makeWebPageController() -> UIViewController? {
        guard let client else { return nil }
        let page = dashboardPage ?? ProactivityBeta.fallbackPage
        let controller = PluginWebPageController(
            page: page,
            profile: profile,
            botName: botName,
            client: client,
            services: services as? AppModel
        )
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }
}

struct ProactivityBetaView: View {
    @Bindable var model: ProactivityBetaModel
    let router: SettingsRouter

    var body: some View {
        List { Group {
            if model.botChoices.count > 1 {
                Section {
                    Picker("Bot", selection: Binding(get: { model.profile }, set: { model.selectProfile($0) })) {
                        ForEach(model.botChoices, id: \.id) { bot in
                            Text(bot.name).tag(bot.id)
                        }
                    }
                    .accessibilityIdentifier("proactivity.bot-picker")
                } header: { HQSectionLabel { Text("Bot Profile") } } footer: {
                    HQSectionFooter { Text("Proactivity (Beta) is configured per bot so you can try it on one bot first.") }
                }
            }

            if let error = model.error {
                Section {
                    Text(error)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                }
            }

            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
            }

            switch model.phase {
            case .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking Proactivity (Beta)…")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                    }
                }

            case .notInstalled:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Proactivity")
                                .font(Font.hq(.headline))
                            Text("BETA")
                                .font(Font.hq(.caption2))
                                .fontWeight(.bold)
                                .foregroundStyle(Color.hqOrange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.hqOrange.opacity(0.16), in: Capsule())
                        }
                        Text("Off by default. Helps \(model.botName) think one step ahead, track soft open loops, and prepare read-only drafts & daily briefs — never sending, booking, buying, paying, posting, or deleting without your approval.")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    .padding(.vertical, 4)

                    Button {
                        Haptics.play(.light)
                        Task { await model.install() }
                    } label: {
                        HStack {
                            Text(model.busy ? "Installing…" : "Install Proactivity (Beta)")
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("proactivity.install")
                } header: { HQSectionLabel { Text("Opt-In Beta Add-On") } } footer: {
                    HQSectionFooter { Text("Installs \(ProactivityBeta.pluginName) from Hermes HQ plugins onto \(model.botName). Even after install, Proactivity stays off until you switch it on.") }
                }

            case .needsRestart:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Restart Hermes to Finish")
                            .font(Font.hq(.headline))
                        Text("\(ProactivityBeta.pluginName) is installed on \(model.botName), but Hermes loads a plugin’s web routes when it starts.")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    .padding(.vertical, 4)

                    if model.canAskRestart {
                        Button("Ask Main Bot to Restart Hermes") {
                            Haptics.play(.light)
                            Task { await model.askToRestart() }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("proactivity.ask-restart")
                    }

                    Button("Check Again") {
                        Haptics.play(.selection)
                        Task { await model.refresh() }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("proactivity.check-again")
                } header: { HQSectionLabel { Text("Almost Ready") } }

            case .failed(let message):
                Section {
                    Text(message)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                    Button("Try Again") {
                        Task { await model.refresh() }
                    }
                    .accessibilityIdentifier("proactivity.retry")
                }

            case .ready(let status):
                readySections(status)
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("settings.proactivity-beta-list")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func readySections(_ status: ProactivityBeta.Status) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { status.enabled },
                set: { next in
                    Haptics.play(.selection)
                    Task {
                        await model.update(
                            ["enabled": .bool(next)],
                            note: next ? "Proactivity (Beta) is on for \(model.botName)." : "Proactivity (Beta) is off for \(model.botName)."
                        )
                    }
                }
            )) {
                SettingsRowLabel(
                    title: "Enable Proactivity (Beta)",
                    systemImage: "sparkles",
                    subtitle: status.enabled ? "Active · v\(status.version)" : "Off by default · 0 overhead while off"
                )
            }
            .disabled(model.busy)
            .accessibilityIdentifier("proactivity.enable-toggle")
        } header: { HQSectionLabel { Text("Beta · v\(status.version)") } } footer: {
            HQSectionFooter {
                Text("Hard safety fence: background sweeps are strictly read-only and draft-only. Sending, booking, buying, paying, posting, or deleting always wait for your approval.")
            }
        }

        if status.enabled {
            Section {
                Picker("Autonomy Mode", selection: Binding(
                    get: { status.autonomyMode },
                    set: { next in
                        Haptics.play(.selection)
                        Task { await model.update(["autonomy_mode": .string(next.rawValue)], note: "Autonomy mode set to \(next.title).") }
                    }
                )) {
                    ForEach(ProactivityBeta.AutonomyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("proactivity.mode-picker")

                Text(status.autonomyMode.detail)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
            } header: { HQSectionLabel { Text("Autonomy") } }

            Section {
                featureToggle("In-Turn Next-Step Anticipation", key: "in_turn_enabled", value: status.inTurnEnabled)
                featureToggle("Open-Loop & Commitment Radar", key: "loop_radar_enabled", value: status.loopRadarEnabled)
                featureToggle("Signal-Gated Idle Sweeps", key: "idle_sweep_enabled", value: status.idleSweepEnabled)
                featureToggle("Unified Daily Brief", key: "daily_brief_enabled", value: status.dailyBriefEnabled)
                featureToggle("Repetition Spotter", key: "pattern_detection_enabled", value: status.patternDetectionEnabled)
            } header: { HQSectionLabel { Text("Capabilities") } }

            Section {
                statusRow("Pending Offers", value: "\(status.pendingOffers)")
                statusRow("Open Loops", value: "\(status.openLoops) open · \(status.snoozedLoops) snoozed")
                statusRow("24h Offer Budget", value: "\(status.offersUsed24h) / \(status.offersLimit24h)")
                statusRow("Quiet Hours", value: "\(status.quietStart)–\(status.quietEnd)" + (status.quietHoursActive ? " (Quiet)" : ""))

                Button("Run Signal Check Now") {
                    Haptics.play(.light)
                    Task { await model.runSweep(forceBrief: false) }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("proactivity.run-sweep")

                Button("Open Proactivity (Beta) Page") {
                    if let controller = model.makeWebPageController() {
                        Haptics.play(.light)
                        router.push(controller)
                    }
                }
                .accessibilityIdentifier("proactivity.open-page")
            } header: { HQSectionLabel { Text("Brief, Offers & Calibration") } } footer: {
                HQSectionFooter {
                    Text("Open the full page to review prepared drafts, manage open loops and watches, adjust quiet hours, or inspect adaptive calibration and audit logs.")
                }
            }
        }
    }

    private func featureToggle(_ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { next in
                Haptics.play(.selection)
                Task { await model.update([key: .bool(next)]) }
            }
        ))
        .disabled(model.busy)
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Font.hq(.subheadline))
            Spacer(minLength: 12)
            Text(value)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
        }
    }
}
