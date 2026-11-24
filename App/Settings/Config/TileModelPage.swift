// [tile-models] Settings › Bots & Tools › Tile Model (owner 2026-11-18: "a global setting and then an individual
// override"). The model the tiles' jobs run (Default Model) and the one they fall back to (Fallback Model), each "each
// bot's own" until one is picked with the app's model chooser. Kept per gateway account (`TileModelSettings`, which
// settings sync carries), and put on every tile's job at once (`TileModelSync.reconcileAll`).

import SwiftUI

struct TileModelView: View {
    let router: SettingsRouter
    let accountId: String
    @State private var catalog: ModelCatalogModel
    @State private var chosen: TileModelPick?
    @State private var fallback: TileModelPick?
    @State private var applying = false
    @State private var status: String?
    @State private var statusIsIssue = false
    /// [tiles-v2] Live summary of scheduled tile jobs & estimated daily model runs.
    @State private var activity: TileActivitySummary?
    @State private var togglingAll = false

    init(router: SettingsRouter, accountId: String) {
        self.router = router
        self.accountId = accountId
        _catalog = State(initialValue: ModelCatalogModel(api: router.gatewaySettings?.settingsAPI))
        let settings = TileModelSettings(accountId: accountId)
        _chosen = State(initialValue: settings.defaultModel)
        _fallback = State(initialValue: settings.fallbackModel)
    }

    private var readOnly: Bool { router.gatewaySettings?.isReadOnlyGateway == true }

    var body: some View {
        List { Group {
            Section {
                choiceRow(TileModels.eachBotsModel, subtitle: nil, selected: chosen == nil, id: "tile-model.default.bots") { setDefault(nil) }
                choiceRow(chosen.map(TileModels.name) ?? "Choose a Model…", subtitle: chosen.map { catalog.providerName($0.provider) },
                          selected: chosen != nil, id: "tile-model.default.pick") { openChooser(fallback: false) }
            } header: { HQSectionLabel { Text("Default Model") } } footer: { HQSectionFooter {
                // Owner 2026-11-18: "I'm using a powerful model for my bots' default, but for quick recurring tasks I'd
                // use a cheaper model." The tiles' model is its own choice, apart from the bots' chat model.
                Text(TileModels.defaultFooter).accessibilityIdentifier("tile-model.default.footer")
            } }
            Section {
                choiceRow(TileModels.eachBotsFallback, subtitle: nil, selected: fallback == nil, id: "tile-model.fallback.bots") { setFallback(nil) }
                choiceRow(fallback.map(TileModels.name) ?? "Choose a Model…", subtitle: fallback.map { catalog.providerName($0.provider) },
                          selected: fallback != nil, id: "tile-model.fallback.pick") { openChooser(fallback: true) }
            } header: { HQSectionLabel { Text("Fallback Model") } } footer: { HQSectionFooter {
                Text(TileModels.footer(default: chosen, fallback: fallback)).accessibilityIdentifier("tile-model.footer")
            } }
            if let activity, activity.totalJobs > 0 {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.headline)
                            .font(Font.hq(.body).weight(.medium))
                            .foregroundStyle(Color.hqLabel)
                        if let detail = activity.detail {
                            Text(detail)
                                .font(Font.hq(.footnote))
                                .foregroundStyle(activity.failingJobs > 0 ? Color.hqRed : Color.hqLabel2)
                        }
                    }
                    .hqRowPadding(4)
                    .accessibilityIdentifier("tile-model.activity")
                    if !readOnly {
                        let willPause = activity.activeJobs > 0
                        Button {
                            toggleAllUpdates(pause: willPause)
                        } label: {
                            HStack {
                                Label(willPause ? "Pause All Tile Updates" : "Resume All Tile Updates",
                                      systemImage: willPause ? "pause.circle" : "play.circle")
                                    .foregroundStyle(Color.hqTint)
                                Spacer()
                                if togglingAll { ProgressView().controlSize(.small) }
                            }
                            .hqRowPadding(4)
                        }
                        .disabled(togglingAll)
                        .accessibilityIdentifier("tile-model.toggle-all")
                    }
                } header: { HQSectionLabel { Text("Tile Activity") } }
            }
            if applying || status != nil || readOnly {
                Section {
                    if applying {
                        HStack(spacing: 10) { ProgressView(); Text("Updating your tiles…").foregroundStyle(Color.hqLabel2) }
                    } else if readOnly {
                        Text(JobsStore.readOnlyNotice).foregroundStyle(Color.hqLabel2)
                    } else if let status {
                        Text(status).foregroundStyle(statusIsIssue ? Color.hqRed : Color.hqLabel2)
                            .accessibilityIdentifier("tile-model.status")
                    }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .disabled(readOnly)
        .task {
            if catalog.providers.isEmpty { await catalog.load() }
            await loadActivity()
        }
        .accessibilityIdentifier("tile-model.list")
    }

    private func choiceRow(_ title: String, subtitle: String?, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.selection)
            action()
        } label: {
            HStack(alignment: DeviceWord.isMac ? .firstTextBaseline : .center, spacing: DeviceWord.isMac ? MacForm.radioGap : nil) {
                HQRadioMark(selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.hqLabel)
                    if let subtitle { Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
                }
                Spacer()
                HQCheckMark(selected: selected)
            }
            .hqRowPadding(4)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .hqRadioRow()
    }

    private func openChooser(fallback isFallback: Bool) {
        let current = isFallback ? fallback : chosen
        let title = isFallback ? "Fallback Model" : "Default Model"
        let view = ModelChooserView(catalog: catalog, title: title, currentProvider: current?.provider ?? "", currentModel: current?.model ?? "",
                                    note: isFallback ? "Tried when a tile’s picked model fails." : "Every tile’s job runs this unless the tile has its own.") {
            provider, model in
            router.closeChooser()
            let pick = TileModelPick(provider: provider, model: model)
            if isFallback { setFallback(pick) } else { setDefault(pick) }
        }
        router.openChooser(title, view)
    }

    private func setDefault(_ pick: TileModelPick?) {
        guard pick != chosen else { return }
        chosen = pick
        TileModelSettings(accountId: accountId).defaultModel = pick
        apply()
    }

    private func setFallback(_ pick: TileModelPick?) {
        guard pick != fallback else { return }
        fallback = pick
        TileModelSettings(accountId: accountId).fallbackModel = pick
        apply()
    }

    /// Every tile's job, at once.
    private func apply() {
        AppLog.note("settings", "tile model: default \(chosen == nil ? "bots" : "picked"), fallback \(fallback == nil ? "bots" : "picked")")
        NotificationCenter.default.post(name: TileModelSync.changed, object: accountId)
        applying = true
        status = nil
        Task {
            let result = await TileModelSync.shared.reconcileAll(accountId: accountId, client: JobsStore.current?.client)
            applying = false
            status = TileModels.appliedWords(changed: result.changed, failed: result.failed)
            statusIsIssue = !result.failed.isEmpty
            if result.failed.isEmpty { Haptics.play(.success) } else { Haptics.play(.error) }
            await loadActivity()
        }
    }

    private func loadActivity() async {
        let pages = ArtifactPins.of(accountId: accountId).pins.filter(\.isPage)
        guard !pages.isEmpty else { activity = nil; return }
        let jobs = await TileUpdates.shared.allJobs(for: pages, accountId: accountId, client: JobsStore.current?.client)
        activity = TileActivitySummary.summarize(jobs)
    }

    private func toggleAllUpdates(pause: Bool) {
        togglingAll = true
        let pages = ArtifactPins.of(accountId: accountId).pins.filter(\.isPage)
        Task {
            _ = await TileUpdates.shared.setAllPaused(pause, pins: pages, accountId: accountId,
                                                      client: JobsStore.current?.client, host: nil)
            togglingAll = false
            await loadActivity()
        }
    }
}
