// [tiles] How often a tile is updated, from the tile itself (owner 2026-11-03: "an easy way to control how frequently
// the tile is updated"). A tile is a page a scheduled job rewrites (`TileJobs.match` finds the job); its hold menu and
// the opened tile's clock button offer how often that job runs, Update Now, and Pause/Resume Updates, and say when it
// last ran ("Updated 5 min ago · hourly"). The writes are the Jobs page's own (`JobsStore`).

import UIKit

extension JobsStore {
    /// The signed-in account's jobs store (set by the Pages tabs), for the tiles' Updates.
    static weak var current: JobsStore?
}

@MainActor
final class TileUpdates {
    static let shared = TileUpdates()
    /// [tiles] A tile's job has just run (object: the pin's id): an open tile reads its page again (`HTMLPageSheet`).
    static let ran = Notification.Name("TileUpdates.ran")
    /// [tiles] A tile's updates were changed from its menu (paused, resumed, run now, how often): the Tiles page reads
    /// the jobs again at once, so the mark follows the choice (it waited up to a minute for the next read).
    static let changed = Notification.Name("TileUpdates.changed")

    /// Each bot's jobs as last read for a tile, by account and bot (read again after `fresh`).
    private var lists: [String: (jobs: [CronJob], at: Date)] = [:]
    static let fresh: TimeInterval = 30

    /// Returns the active `JobsStore` only when it belongs to `accountId` (never leaks or mutates across accounts).
    private func store(for accountId: String) -> JobsStore? {
        guard let store = JobsStore.current, store.account.id == accountId else { return nil }
        return store
    }

    /// The job keeping `pin` up to date, nil when none does (or the jobs can't be read).
    func job(for pin: ArtifactPin, accountId: String, client: (any GatewayClient)?, fresh: TimeInterval = TileUpdates.fresh) async -> CronJob? {
        await lookup(pin, accountId: accountId, client: client, fresh: fresh).job
    }

    /// The job keeping `pin` up to date, and whether that is known: `known` is false when the bot's jobs couldn't be
    /// read and the Jobs page's saved list has no job for the tile (it may be on another bot, or never loaded), so
    /// "no job" there is a guess, not an answer.
    func lookup(_ pin: ArtifactPin, accountId: String, client: (any GatewayClient)?,
                fresh: TimeInterval = TileUpdates.fresh) async -> (job: CronJob?, known: Bool) {
        guard pin.isPage, let path = pin.gatewayPath else { return (nil, true) }
        let key = accountId + "|" + pin.profile
        var jobs: [CronJob]
        var read = true
        if let kept = lists[key], Date().timeIntervalSince(kept.at) < fresh {
            jobs = kept.jobs
        } else if let client, let list = try? await JobsStore.readList(client, scope: pin.profile) {
            jobs = list
            lists[key] = (list, Date())
        } else {
            jobs = store(for: accountId)?.jobs ?? []
            read = false
        }
        // The Jobs page's copy is newer after a change made there.
        if let store = store(for: accountId) {
            jobs = jobs.map { store.job(key: $0.key) ?? $0 }
        }
        let job = TileJobs.match(path: path, profile: pin.profile, jobId: pin.jobId, jobs: jobs)
        return (job, read || job != nil)
    }

    // MARK: Health (the tile's mark) and redrawing when its job has run

    /// Each tile's health and its job's last run as last read, by pin id.
    private(set) var healths: [String: TileJobs.Health] = [:]
    private var lastRuns: [String: String] = [:]
    private var updating: Set<String> = []

    func health(_ id: String) -> TileJobs.Health { healths[id] ?? .none }
    /// A tile's job is running (its page is read again sooner, to redraw it as the run ends).
    var anyUpdating: Bool { !updating.isEmpty }

    /// [tiles-v2] Reads the jobs for `profiles` concurrently in one pass so multi-bot accounts don't wait serially.
    func prefetch(profiles: [String], accountId: String, client: (any GatewayClient)?) async {
        guard let client else { return }
        let unique = Array(Set(profiles))
        guard !unique.isEmpty else { return }
        var fetched: [(String, [CronJob])] = []
        await withChildTasks(of: (String, [CronJob]?).self) { group in
            for profile in unique {
                // The read before the tuple: `(key, try await f())` can lose `key` in -O builds (Swift tuple bug).
                group.addTask { let list = try? await JobsStore.readList(client, scope: profile); return (profile, list) }
            }
            while let (profile, list) = await group.next() { if let list { fetched.append((profile, list)) } }
        }
        let now = Date()
        for (profile, list) in fetched {
            lists[accountId + "|" + profile] = (list, now)
        }
    }

    /// [tiles-v2] All matched tile jobs for `pins` (one per unique job key), fetched concurrently per bot.
    func allJobs(for pins: [ArtifactPin], accountId: String, client: (any GatewayClient)?) async -> [CronJob] {
        let pages = pins.filter(\.isPage)
        guard !pages.isEmpty else { return [] }
        await prefetch(profiles: pages.map(\.profile), accountId: accountId, client: client)
        var seen: Set<String> = []
        var out: [CronJob] = []
        for pin in pages {
            let (job, _) = await lookup(pin, accountId: accountId, client: client, fresh: Self.fresh)
            if let job, seen.insert(job.key).inserted { out.append(job) }
        }
        return out
    }

    /// Reads the tiles' jobs again (one concurrent read per bot). Returns the tiles whose mark changed, and those whose
    /// job ran since the last read (or ended a run): their pictures are drawn again (owner 2026-11-03: "redraw the
    /// moment the job finishes").
    /// [tile-models] Each job then gets the model Settings › Tile Model and its tile ask for (one write, not retried while
    /// the settings stay as they are); `modelFailed` is the reason one couldn't be written.
    func refresh(_ pins: [ArtifactPin], accountId: String, client: (any GatewayClient)?) async
        -> (marks: [String], ran: [String], modelFailed: String?) {
        var marks: [String] = []
        var ran: [String] = []
        var modelFailed: String?
        var reconciled: Set<String> = []
        let pages = pins.filter(\.isPage)
        for profile in Set(pages.map(\.profile)) { lists[accountId + "|" + profile] = nil }
        await prefetch(profiles: pages.map(\.profile), accountId: accountId, client: client)
        for pin in pages {
            let (job, known) = await lookup(pin, accountId: accountId, client: client, fresh: 15)
            // Unread (offline): the mark stays as it was, never dropped for a guess.
            guard known else { continue }
            if let job, reconciled.insert(job.key).inserted,
               case .failed(let why) = await TileModelSync.shared.reconcile(job, accountId: accountId, force: false) {
                modelFailed = why
            }
            let health = TileJobs.health(job)
            if healths[pin.id] != health { marks.append(pin.id) }
            healths[pin.id] = health
            let last = job?.lastRunAt ?? ""
            let wasUpdating = updating.contains(pin.id)
            if health == .updating { updating.insert(pin.id) } else { updating.remove(pin.id) }
            if let seen = lastRuns[pin.id], seen != last || (wasUpdating && health != .updating) { ran.append(pin.id) }
            lastRuns[pin.id] = last
        }
        for id in ran { NotificationCenter.default.post(name: Self.ran, object: id) }   // an open tile reads its page again
        return (marks, ran, modelFailed)
    }

    private func forget(_ pin: ArtifactPin, accountId: String) { lists[accountId + "|" + pin.profile] = nil }

    /// The Updates part of a tile's menu, read when the menu opens. `redraw`: the tile's picture again (after Update Now).
    /// `inline`: the choices themselves, under the update line (the opened tile's clock button); else an Updates
    /// submenu (the tile's hold menu).
    /// `botName`/`botModel`: the tile's bot and its own model, for "Updated by" (owner 2026-11-03: "understanding how
    /// often it updates and what model is updating it").
    func menu(for pin: ArtifactPin, accountId: String, client: (any GatewayClient)?, from host: UIViewController, inline: Bool = false,
              botName: String, botModel: String?,
              onKeepUpdated: ((TileJobs.Frequency) -> Void)? = nil,
              onFixFailed: ((String?) -> Void)? = nil,
              onOpenJob: ((CronJob) -> Void)? = nil,
              redraw: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self, weak host] completion in
            Task { @MainActor in
                guard let self else { completion([]); return }
                let (job, known) = await self.lookup(pin, accountId: accountId, client: client)
                // [tile-models] The model by name, read from the gateway when the roster doesn't have it; and the short
                // list of models the tile offers.
                var models = TileModelMenu(botModel: botModel)
                if let job, !TileModels.isScriptOnly(job) {
                    let sync = TileModelSync.shared
                    let settings = TileModelSettings(accountId: accountId)
                    models.botModel = await sync.botModel(pin.profile, known: botModel, accountId: accountId, client: client)
                    models.override = settings.override(job.key)
                    models.defaultModel = settings.defaultModel
                    models.list = await sync.shortList(accountId: accountId, profile: pin.profile, client: client, keep: models.override)
                }
                completion([self.updates(pin, job: job, known: known, accountId: accountId, client: client, host: host, inline: inline,
                                         botName: botName, models: models, onKeepUpdated: onKeepUpdated, onFixFailed: onFixFailed,
                                         onOpenJob: onOpenJob, redraw: redraw)])
            }
        }
    }

    /// [tile-models] What the Model submenu shows.
    struct TileModelMenu {
        var botModel: String?
        var override: TileModelPick?
        var defaultModel: TileModelPick?
        var list: [TileModelPick] = []
    }

    private func updates(_ pin: ArtifactPin, job: CronJob?, known: Bool = true, accountId: String, client: (any GatewayClient)?,
                         host: UIViewController?, inline: Bool, botName: String, models: TileModelMenu,
                         onKeepUpdated: ((TileJobs.Frequency) -> Void)?,
                         onFixFailed: ((String?) -> Void)?,
                         onOpenJob: ((CronJob) -> Void)?,
                         redraw: @escaping () -> Void) -> UIMenuElement {
        guard known else {
            let unread = UIAction(title: "Couldn’t Read Updates", subtitle: "Can’t reach your gateway", image: UIImage(systemName: "clock"),
                                  attributes: .disabled) { _ in }
            unread.accessibilityIdentifier = "tile.updates.unread"
            return UIMenu(options: .displayInline, children: [unread])
        }
        guard let job else {
            let store = store(for: accountId)
            let writable = store != nil && store?.readOnlyGateway == false
            // [tiles-v2] Turn the dead-end "Not Kept Updated" row into an actionable "Keep Updated…" schedule picker.
            if writable, let onKeepUpdated {
                let choices: [UIMenuElement] = TileJobs.frequencies.map { frequency in
                    let action = UIAction(title: frequency.title) { _ in onKeepUpdated(frequency) }
                    action.accessibilityIdentifier = "tile.updates.attach-\(frequency.minutes)"
                    return action
                }
                let attach = UIMenu(title: "Keep Updated…", subtitle: "Ask \(botName) to schedule refreshes",
                                    image: UIImage(systemName: "clock.badge.plus"), children: choices)
                attach.accessibilityIdentifier = "tile.updates.attach"
                return UIMenu(options: .displayInline, children: [attach])
            }
            let none = UIAction(title: "Not Kept Updated", subtitle: "No job rewrites this tile", image: UIImage(systemName: "clock"),
                                attributes: .disabled) { _ in }
            none.accessibilityIdentifier = "tile.updates.none"
            return UIMenu(options: .displayInline, children: [none])
        }
        let store = store(for: accountId)
        let writable = store != nil && store?.readOnlyGateway == false
        let current = TileJobs.frequency(of: job)
        var choices: [UIMenuElement] = TileJobs.frequencies.map { frequency in
            let action = UIAction(title: frequency.title, state: current == frequency ? .on : .off) { [weak self, weak host] _ in
                self?.setFrequency(frequency, job: job, pin: pin, accountId: accountId, host: host)
            }
            if !writable { action.attributes = .disabled }
            action.accessibilityIdentifier = "tile.updates.every-\(frequency.minutes)"
            return action
        }
        if current == nil {
            // Its own time ("weekdays at 9"): shown, ticked, and kept until another is chosen.
            choices.insert(UIAction(title: TileJobs.howOften(job).capitalizedFirst, state: .on) { _ in }, at: 0)
        }
        let often = UIMenu(title: "How Often", options: [.displayInline, .singleSelection], children: choices)
        let paused = TileJobs.isPaused(job)
        let isFailed: Bool
        let failureReason: String?
        if case .failed(let why) = TileJobs.health(job) {
            isFailed = true; failureReason = why
        } else {
            isFailed = false; failureReason = nil
        }
        let now = UIAction(title: isFailed ? "Retry Now" : "Update Now", image: UIImage(systemName: "arrow.clockwise")) { [weak self, weak host] _ in
            self?.updateNow(job, pin: pin, accountId: accountId, client: client, host: host, redraw: redraw)
        }
        now.accessibilityIdentifier = "tile.updates.now"
        let pause = UIAction(title: paused ? "Resume Updates" : "Pause Updates", image: UIImage(systemName: paused ? "play" : "pause")) {
            [weak self, weak host] _ in
            self?.setPaused(!paused, job: job, pin: pin, accountId: accountId, host: host)
        }
        pause.accessibilityIdentifier = "tile.updates.pause"
        if !writable { now.attributes = .disabled; pause.attributes = .disabled }
        // What runs it (a choice, [tile-models]) and, after a failed run, why it failed + one-tap recovery actions.
        var about: [UIMenuElement] = []
        if TileModels.isScriptOnly(job) {
            let model = UIAction(title: TileJobs.modelWords(job, botName: botName, botModel: models.botModel), subtitle: "Updates this tile",
                                 image: UIImage(systemName: "terminal"), attributes: .disabled) { _ in }
            model.accessibilityIdentifier = "tile.updates.model"
            about.append(model)
        } else {
            about.append(modelMenu(pin, job: job, accountId: accountId, client: client, host: host, botName: botName, models: models,
                                   writable: writable))
        }
        if isFailed {
            let failed = UIAction(title: "Last Update Failed", subtitle: failureReason.map { String($0.prefix(120)) },
                                  image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }
            failed.accessibilityIdentifier = "tile.updates.failed"
            about.append(failed)
            if writable, let onFixFailed {
                let fix = UIAction(title: "Fix with \(botName)…", image: UIImage(systemName: "wrench.and.screwdriver")) { _ in
                    onFixFailed(failureReason)
                }
                fix.accessibilityIdentifier = "tile.updates.fix"
                about.append(fix)
            }
            if let onOpenJob {
                let viewRun = UIAction(title: "View Last Run", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in
                    onOpenJob(job)
                }
                viewRun.accessibilityIdentifier = "tile.updates.view-run"
                about.append(viewRun)
            }
        } else if let onOpenJob {
            let viewJob = UIAction(title: "View Job", image: UIImage(systemName: "clock.badge.checkmark")) { _ in
                onOpenJob(job)
            }
            viewJob.accessibilityIdentifier = "tile.updates.view-job"
            about.append(viewJob)
        }
        let children: [UIMenuElement] = [UIMenu(options: .displayInline, children: about), often,
                                          UIMenu(options: .displayInline, children: [now, pause])]
        // [tile-models] The model by name beside how often ("Updated 5 min ago · hourly · GPT-6.2 Astra").
        let subtitle = TileModels.updatesSubtitle(job, botModel: models.botModel)
        if inline { return UIMenu(title: subtitle, options: .displayInline, children: children) }
        let menu = UIMenu(title: "Updates", subtitle: subtitle, image: UIImage(systemName: "clock.arrow.circlepath"),
                          children: children)
        menu.accessibilityIdentifier = "tile.updates"
        return menu
    }

    /// [tile-models] Updates › Model: the tile default (ticked unless the tile has its own), a short list of the account's
    /// models, and Other Model… (the app's chooser). Its line says what runs it now.
    private func modelMenu(_ pin: ArtifactPin, job: CronJob, accountId: String, client: (any GatewayClient)?, host: UIViewController?,
                           botName: String, models: TileModelMenu, writable: Bool) -> UIMenuElement {
        let useDefault = UIAction(title: TileModels.useDefaultTitle(default: models.defaultModel, botName: botName, botModel: models.botModel),
                                  state: models.override == nil ? .on : .off) { [weak self, weak host] _ in
            self?.setModel(nil, job: job, pin: pin, accountId: accountId, host: host)
        }
        useDefault.accessibilityIdentifier = "tile.model.default"
        let picks: [UIMenuElement] = models.list.map { pick in
            let chosen = models.override.map { $0.model == pick.model && $0.provider.lowercased() == pick.provider.lowercased() } ?? false
            let action = UIAction(title: TileModels.name(pick), subtitle: pick.provider.isEmpty ? nil : ModelNames.providerDisplayName(pick.provider),
                                  state: chosen ? .on : .off) { [weak self, weak host] _ in
                self?.setModel(pick, job: job, pin: pin, accountId: accountId, host: host)
            }
            action.accessibilityIdentifier = "tile.model.option.\(pick.model)"
            return action
        }
        let other = UIAction(title: "Other Model…", image: UIImage(systemName: "ellipsis.circle")) { [weak self, weak host] _ in
            guard let host, let client else { return }
            TileModelSync.openChooser(profile: pin.profile, botName: botName, current: models.override, client: client, from: host) {
                [weak self, weak host] pick in
                self?.setModel(pick, job: job, pin: pin, accountId: accountId, host: host)
            }
        }
        other.accessibilityIdentifier = "tile.model.other"
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: [useDefault])]
        if !picks.isEmpty { children.append(UIMenu(options: .displayInline, children: picks)) }
        children.append(UIMenu(options: .displayInline, children: [other]))
        if !writable {
            for case let action as UIAction in [useDefault, other] + picks { action.attributes = .disabled }
        }
        let menu = UIMenu(title: "Model", subtitle: TileModels.modelSubtitle(job, botName: botName, botModel: models.botModel),
                          image: UIImage(systemName: "cpu"), children: children)
        menu.accessibilityIdentifier = "tile.updates.model"
        return menu
    }

    /// [tile-models] The tile's own model (nil: the tile default), kept and put on its job at once.
    private func setModel(_ pick: TileModelPick?, job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?) {
        PagesHaptics.selection()
        TileModelSettings(accountId: accountId).setOverride(pick, for: job.key)
        Task { [weak self, weak host] in
            let outcome = await TileModelSync.shared.reconcile(job, accountId: accountId, force: true)
            self?.forget(pin, accountId: accountId)
            NotificationCenter.default.post(name: Self.changed, object: pin.id)
            guard let host else { return }
            switch outcome {
            case .failed:
                PagesHaptics.error()
                PagesHUD.show("Couldn’t Change the Model", symbol: "exclamationmark.triangle", from: host)
            case .changed, .unchanged:
                AppLog.trace("pages", "tile model \(pick == nil ? "follows the default" : "set for this tile")")
                PagesHUD.show(pick.map { TileModels.name($0) } ?? "Tile Default", symbol: "cpu", from: host)
            }
        }
    }

    private func setFrequency(_ frequency: TileJobs.Frequency, job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?) {
        guard let store = store(for: accountId) else { return }
        PagesHaptics.selection()
        Task { [weak self, weak host] in
            let result = await store.update(job, updates: .object(["schedule": .string(frequency.cron)]))
            self?.forget(pin, accountId: accountId)
            guard let host else { return }
            if case .done = result {
                AppLog.trace("pages", "tile updates every \(frequency.minutes) min")
                NotificationCenter.default.post(name: Self.changed, object: pin.id)
                PagesHUD.show("Updates \(frequency.title)", symbol: "clock.arrow.circlepath", from: host)
            } else {
                AppLog.note("pages", "tile updates change failed: \(result)")
                PagesHaptics.error()
                PagesHUD.show("Couldn’t Change Updates", symbol: "exclamationmark.triangle", from: host)
            }
        }
    }

    private func setPaused(_ pause: Bool, job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?) {
        guard let store = store(for: accountId) else { return }
        PagesHaptics.selection()
        Task { [weak self, weak host] in
            let result = await store.setPaused(job, pause)
            self?.forget(pin, accountId: accountId)
            guard let host else { return }
            if result == .done {
                NotificationCenter.default.post(name: Self.changed, object: pin.id)
                PagesHUD.show(pause ? "Updates Paused" : "Updates Resumed", symbol: pause ? "pause.fill" : "play.fill", from: host)
            } else {
                PagesHaptics.error()
                PagesHUD.show("Couldn’t Change Updates", symbol: "exclamationmark.triangle", from: host)
            }
        }
    }

    private var activePolls: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    private func updateNow(_ job: CronJob, pin: ArtifactPin, accountId: String, client: (any GatewayClient)?,
                           host: UIViewController?, redraw: @escaping () -> Void) {
        guard let store = store(for: accountId) else { return }
        Haptics.play(.soft)
        if let host { PagesHUD.show("Updating…", symbol: "arrow.clockwise", from: host) }
        let priorRun = job.lastRunAt ?? ""
        let token = UUID()
        activePolls[pin.id]?.task.cancel()
        let task = Task { [weak self, weak host] in
            defer {
                if self?.activePolls[pin.id]?.token == token {
                    self?.activePolls[pin.id] = nil
                }
            }
            let result = await store.runNow(job)
            self?.forget(pin, accountId: accountId)
            switch result {
            case .started, .stillRunning, .alreadyRunning:
                AppLog.trace("pages", "tile update now: \(result)")
                NotificationCenter.default.post(name: Self.changed, object: pin.id)
                // [tiles-v2] Poll job state actively (every 4 s, up to 3 min) instead of blind [20, 60, 180] sleeps,
                // redrawing the instant the run completes.
                var sawRunning = false
                for _ in 0..<45 {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, let self else { return }
                    let (latest, known) = await self.lookup(pin, accountId: accountId, client: client, fresh: 0)
                    guard known, let latest else { continue }
                    let running = JobWords.workIsOut(latest)
                    if running { sawRunning = true }
                    let finished = (latest.lastRunAt ?? "") != priorRun || (sawRunning && !running)
                    if finished {
                        NotificationCenter.default.post(name: Self.ran, object: pin.id)
                        NotificationCenter.default.post(name: Self.changed, object: pin.id)
                        redraw()
                        return
                    }
                }
                redraw()
            default:
                AppLog.note("pages", "tile update now failed: \(result)")
                PagesHaptics.error()
                if let host { PagesHUD.show("Couldn’t Update", symbol: "exclamationmark.triangle", from: host) }
            }
        }
        activePolls[pin.id] = (token, task)
    }

    /// [tiles-v2] Page-level Update All Now: triggers every active (non-paused) scheduled job for `pins`.
    func updateAll(_ pins: [ArtifactPin], accountId: String, client: (any GatewayClient)?,
                   host: UIViewController?, redraw: @escaping (String) -> Void) {
        guard let store = store(for: accountId), !store.readOnlyGateway else { return }
        Haptics.play(.soft)
        Task { [weak self, weak host] in
            guard let self else { return }
            let pages = pins.filter(\.isPage)
            await self.prefetch(profiles: pages.map(\.profile), accountId: accountId, client: client)
            var matched: [(ArtifactPin, CronJob)] = []
            var seen: Set<String> = []
            for pin in pages {
                let (job, _) = await self.lookup(pin, accountId: accountId, client: client, fresh: Self.fresh)
                if let job, !TileJobs.isPaused(job), seen.insert(job.key).inserted {
                    matched.append((pin, job))
                }
            }
            guard !matched.isEmpty else {
                if let host { PagesHUD.show("No Active Tile Jobs", symbol: "clock", from: host) }
                return
            }
            if let host {
                let word = matched.count == 1 ? "Updating 1 Tile…" : "Updating \(matched.count) Tiles…"
                PagesHUD.show(word, symbol: "arrow.clockwise", from: host)
            }
            for (pin, job) in matched {
                let result = await store.runNow(job)
                if case .started = result { self.forget(pin, accountId: accountId) }
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            // Watch jobs finish via the Tiles page's fast 15s watchTiles loop; also do a quick check at 10s.
            try? await Task.sleep(for: .seconds(10))
            for (pin, _) in matched { redraw(pin.id) }
        }
    }

    /// [tiles-v2] Batch pause or resume all scheduled tile jobs for `pins`.
    func setAllPaused(_ pause: Bool, pins: [ArtifactPin], accountId: String, client: (any GatewayClient)?,
                      host: UIViewController?) async -> Int {
        guard let store = store(for: accountId), !store.readOnlyGateway else { return 0 }
        let jobs = await allJobs(for: pins, accountId: accountId, client: client)
        let targets = jobs.filter { TileJobs.isPaused($0) != pause }
        var changed = 0
        for job in targets {
            if await store.setPaused(job, pause) == .done { changed += 1 }
        }
        for profile in Set(pins.map(\.profile)) { lists[accountId + "|" + profile] = nil }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        if let host {
            if changed > 0 {
                PagesHaptics.success()
                let word = pause ? (changed == 1 ? "Paused 1 Tile" : "Paused \(changed) Tiles")
                                 : (changed == 1 ? "Resumed 1 Tile" : "Resumed \(changed) Tiles")
                PagesHUD.show(word, symbol: pause ? "pause.fill" : "play.fill", from: host)
            } else {
                PagesHUD.show(pause ? "Already Paused" : "Already Running", symbol: "clock", from: host)
            }
        }
        return changed
    }

    /// Rename…: the tile's own name (empty goes back to the page's).
    static func renameAction(_ pin: ArtifactPin, pins: ArtifactPins, from host: UIViewController) -> UIAction {
        let action = UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak host, weak pins] _ in
            guard let host, let pins else { return }
            // Audit 863 (08b-12): the words for what the tile is (a picture, a file or a link has no page).
            let own = pin.isPage ? "page’s" : pin.kind == .image ? "picture’s" : pin.kind == .link ? "link’s" : "file’s"
            let alert = UIAlertController(title: "Rename Tile", message: "Leave it empty to use the \(own) own name.", preferredStyle: .alert)
            // Mac polish #45: its name as the tiles show it ("Index.md" beside another "Index"), and that name typed
            // back is no rename either.
            let automatic = pin.namedByFile ? pins.name(pin) : pin.automaticName
            alert.addTextField { field in
                field.text = pins.name(pin)
                field.placeholder = automatic
                field.autocapitalizationType = .words
                field.clearButtonMode = .whileEditing
                field.accessibilityIdentifier = "tile.rename.field"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            let save = UIAlertAction(title: "Rename", style: .default) { [weak alert, weak pins] _ in
                let words = alert?.textFields?.first?.text ?? ""
                let typed = words.trimmingCharacters(in: .whitespaces)
                // The automatic name typed back is no rename.
                pins?.rename(id: pin.id, to: typed == automatic || typed == pin.automaticName ? "" : words)
                PagesHaptics.success()
                AppLog.trace("pages", "tile renamed")
            }
            alert.addAction(save)
            alert.preferredAction = save
            host.present(alert, animated: true)
        }
        action.accessibilityIdentifier = "tile.rename"
        return action
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
