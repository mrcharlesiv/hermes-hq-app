// [tile-models] Puts Settings › Tile Model and each tile's own model onto the tiles' jobs (owner 2026-11-18: "a lot of
// tiles are running and I don't know what model they're using"). The rules are `TileModels.desired` (HermesKit); this
// writes what they ask for with the Jobs page's own call (`JobsStore.update`), at most one write per job per change:
//   - Settings › Tile Model changed: every tile on the account (`reconcileAll`).
//   - A tile's Updates › Model picked: that tile (`reconcile(force:)`).
//   - The Tiles page read its jobs (`TileUpdates.refresh`): any job that drifted, once (a failed write isn't tried
//     again until the settings change).
// It also names the model a tile's bot runs, when the roster doesn't say (`botModel`).

import SwiftUI
import UIKit

@MainActor
final class TileModelSync {
    static let shared = TileModelSync()
    /// Settings › Tile Model was changed (object: the account id): the Tiles page's menus read it again.
    static let changed = Notification.Name("TileModelSync.changed")

    /// Writes in flight, by account and job key.
    private var inFlight: Set<String> = []
    /// The last change tried on each job by a quiet pass (the Tiles page's read), so a failed one isn't sent each minute.
    private var tried: [String: TileModels.Plan] = [:]

    enum Outcome: Equatable {
        case unchanged
        case changed
        case failed(String)
    }

    /// One job's change, written when it needs one. `force`: the owner just asked (a pick, a setting), so a change that
    /// failed before is tried again.
    func reconcile(_ job: CronJob, accountId: String, force: Bool) async -> Outcome {
        guard let store = JobsStore.current, store.account.id == accountId else { return .unchanged }
        let settings = TileModelSettings(accountId: accountId)
        let key = accountId + "|" + job.key
        guard let plan = settings.plan(job) else { tried[key] = nil; return .unchanged }
        guard !store.readOnlyGateway, !inFlight.contains(key) else { return .unchanged }
        if !force, tried[key] == plan { return .unchanged }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        tried[key] = plan
        let result = await store.update(job, updates: plan.updates)
        switch result {
        case .done:
            settings.wrote(plan, to: job.key)
            AppLog.note("pages", "tile model: job \(AppLog.tag(job.id)) \(plan.pin == nil ? "unpinned" : "pinned")"
                        + (plan.fallback == .leave ? "" : ", fallback \(plan.fallback == .clear ? "cleared" : "set")"))
            return .changed
        case .refused:
            return .failed(JobsStore.readOnlyNotice)
        case .failed(let reason, _, _):
            AppLog.note("pages", "tile model: job \(AppLog.tag(job.id)) write failed: \(result)")
            return .failed(reason)
        }
    }

    /// Every tile on the account, after Settings › Tile Model changed: how many jobs changed, and why any failed.
    func reconcileAll(accountId: String, client: (any GatewayClient)?) async -> (changed: Int, failed: [String]) {
        let pages = ArtifactPins.of(accountId: accountId).pins.filter(\.isPage)
        // [tiles-v2] Prefetch per-bot job lists concurrently before reconciling.
        await TileUpdates.shared.prefetch(profiles: pages.map(\.profile), accountId: accountId, client: client)
        var seen: Set<String> = []
        var changed = 0
        var failed: [String] = []
        for pin in pages {
            let (job, _) = await TileUpdates.shared.lookup(pin, accountId: accountId, client: client, fresh: TileUpdates.fresh)
            guard let job, seen.insert(job.key).inserted else { continue }
            switch await reconcile(job, accountId: accountId, force: true) {
            case .unchanged: break
            case .changed: changed += 1
            case .failed(let why): failed.append(why)
            }
        }
        if changed > 0 || !failed.isEmpty { NotificationCenter.default.post(name: TileUpdates.changed, object: nil) }
        AppLog.note("pages", "tile model settings applied: \(changed) changed, \(failed.count) failed, \(seen.count) jobs")
        return (changed, failed)
    }

    // MARK: The bot's model, by name

    private var botModels: [String: (name: String?, at: Date)] = [:]

    /// The model `profile`'s bot runs, by name: the roster's when it has one, else read from the gateway
    /// (`GET /api/model/info?profile=`, kept 10 minutes), so a tile never says "Otto's own model" when the name can be found.
    func botModel(_ profile: String, known: String?, accountId: String, client: (any GatewayClient)?) async -> String? {
        if let known, !known.isEmpty { return known }
        let key = accountId + "|" + profile
        if let kept = botModels[key], Date().timeIntervalSince(kept.at) < 600 { return kept.name }
        guard let client else { return nil }
        let api = GatewaySettingsAPI(client: client, profile: BotModelPages.isDefault(profile) ? nil : profile)
        guard let info = try? await api.modelInfo(), let model = info["model"]?.string, !model.isEmpty else {
            botModels[key] = (nil, Date())
            return nil
        }
        let provider = info["provider"]?.string ?? ""
        let name = provider.isEmpty ? ModelNames.displayModelName(model) : ModelNames.displayModelName(model, provider: provider)
        botModels[key] = (name, Date())
        return name
    }

    // MARK: The models a tile offers

    private var catalogs: [String: (picks: [TileModelPick], at: Date)] = [:]

    /// The account's starred and recent models; when it has none, the first models of the bot's own provider.
    func shortList(accountId: String, profile: String, client: (any GatewayClient)?, keep: TileModelPick?) async -> [TileModelPick] {
        let prefs = ModelPrefs(accountId: accountId)
        let recents = prefs.recents.map { TileModelPick(provider: $0.provider, model: $0.id) }
        var catalog: [TileModelPick] = []
        if prefs.favorites.isEmpty, recents.isEmpty {
            let key = accountId + "|" + profile
            if let kept = catalogs[key], Date().timeIntervalSince(kept.at) < 600 {
                catalog = kept.picks
            } else if let client, let rows = try? await GatewaySettingsAPI(client: client, profile: BotModelPages.isDefault(profile) ? nil : profile)
                        .modelOptions() {
                let ready = rows.filter(\.isReady)
                let first = ready.first(where: \.isCurrent) ?? ready.first
                catalog = (first?.models ?? []).prefix(6).map { TileModelPick(provider: first?.slug ?? "", model: $0) }
                catalogs[key] = (catalog, Date())
            }
        }
        return TileModels.shortList(favorites: prefs.favorites, recents: recents, catalog: catalog, keep: keep)
    }

    // MARK: Other Model…

    /// The app's model chooser on the tile's bot's catalog, as a sheet over `host`; a pick goes to `picked`.
    static func openChooser(profile: String, botName: String, current: TileModelPick?, client: any GatewayClient, from host: UIViewController,
                            picked: @escaping (TileModelPick) -> Void) {
        let catalog = ModelCatalogModel(api: GatewaySettingsAPI(client: client, profile: BotModelPages.isDefault(profile) ? nil : profile))
        weak var sheetRef: UINavigationController?
        let chooser = ModelChooserView(catalog: catalog, title: "Tile Model", currentProvider: current?.provider ?? "",
                                       currentModel: current?.model ?? "",
                                       note: "This tile alone. \(botName) keeps its own model for everything else.") { provider, model in
            sheetRef?.dismiss(animated: true)
            picked(TileModelPick(provider: provider, model: model))
        }
        let page = SettingsPageController(title: "Tile Model", chooser.environment(\.macFormLeastSide, MacForm.sheetSide))
        let sheet = UINavigationController(rootViewController: page)
        sheetRef = sheet
        // [popup-consistency] A pick-or-close chooser, as the chat's Models sheet: the system ✕ named Close on the iPhone
        // (`.cancel` drew the same ✕ but VoiceOver called it Cancel), the word Cancel on the Mac.
        page.navigationItem.leftBarButtonItem = .hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak sheet] _ in
            sheet?.dismiss(animated: true)
        })
        SheetStyle.apply(sheet, from: host, fixed: .greatestFiniteMagnitude)
        host.present(sheet, animated: true)
    }
}
