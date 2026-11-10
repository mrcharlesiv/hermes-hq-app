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

    /// Each bot's jobs as last read for a tile, by account and bot (read again after `fresh`).
    private var lists: [String: (jobs: [CronJob], at: Date)] = [:]
    static let fresh: TimeInterval = 30

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
            jobs = JobsStore.current?.jobs ?? []
            read = false
        }
        // The Jobs page's copy is newer after a change made there.
        if let store = JobsStore.current, store.account.id == accountId {
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

    /// Reads the tiles' jobs again (one read per bot). Returns the tiles whose mark changed, and those whose job ran
    /// since the last read (or ended a run): their pictures are drawn again (owner 2026-11-03: "redraw the moment the
    /// job finishes").
    func refresh(_ pins: [ArtifactPin], accountId: String, client: (any GatewayClient)?) async -> (marks: [String], ran: [String]) {
        var marks: [String] = []
        var ran: [String] = []
        let pages = pins.filter(\.isPage)
        for profile in Set(pages.map(\.profile)) { lists[accountId + "|" + profile] = nil }
        for pin in pages {
            let (job, known) = await lookup(pin, accountId: accountId, client: client, fresh: 5)
            // Unread (offline): the mark stays as it was, never dropped for a guess.
            guard known else { continue }
            let health = TileJobs.health(job)
            if healths[pin.id] != health { marks.append(pin.id) }
            healths[pin.id] = health
            let last = job?.lastRunAt ?? ""
            let wasUpdating = updating.contains(pin.id)
            if health == .updating { updating.insert(pin.id) } else { updating.remove(pin.id) }
            if let seen = lastRuns[pin.id], seen != last || (wasUpdating && health != .updating) { ran.append(pin.id) }
            lastRuns[pin.id] = last
        }
        return (marks, ran)
    }

    private func forget(_ pin: ArtifactPin, accountId: String) { lists[accountId + "|" + pin.profile] = nil }

    /// The Updates part of a tile's menu, read when the menu opens. `redraw`: the tile's picture again (after Update Now).
    /// `inline`: the choices themselves, under the update line (the opened tile's clock button); else an Updates
    /// submenu (the tile's hold menu).
    /// `botName`/`botModel`: the tile's bot and its own model, for "Updated by" (owner 2026-11-03: "understanding how
    /// often it updates and what model is updating it").
    func menu(for pin: ArtifactPin, accountId: String, client: (any GatewayClient)?, from host: UIViewController, inline: Bool = false,
              botName: String, botModel: String?, redraw: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self, weak host] completion in
            Task { @MainActor in
                guard let self else { completion([]); return }
                let (job, known) = await self.lookup(pin, accountId: accountId, client: client)
                completion([self.updates(pin, job: job, known: known, accountId: accountId, host: host, inline: inline, botName: botName,
                                         botModel: botModel, redraw: redraw)])
            }
        }
    }

    private func updates(_ pin: ArtifactPin, job: CronJob?, known: Bool = true, accountId: String, host: UIViewController?, inline: Bool,
                         botName: String, botModel: String?, redraw: @escaping () -> Void) -> UIMenuElement {
        guard known else {
            let unread = UIAction(title: "Couldn’t Read Updates", subtitle: "Can’t reach your gateway", image: UIImage(systemName: "clock"),
                                  attributes: .disabled) { _ in }
            unread.accessibilityIdentifier = "tile.updates.unread"
            return UIMenu(options: .displayInline, children: [unread])
        }
        guard let job else {
            let none = UIAction(title: "Not Kept Updated", subtitle: "No job rewrites this tile", image: UIImage(systemName: "clock"),
                                attributes: .disabled) { _ in }
            none.accessibilityIdentifier = "tile.updates.none"
            return UIMenu(options: .displayInline, children: [none])
        }
        let store = JobsStore.current
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
        let now = UIAction(title: "Update Now", image: UIImage(systemName: "arrow.clockwise")) { [weak self, weak host] _ in
            self?.updateNow(job, pin: pin, accountId: accountId, host: host, redraw: redraw)
        }
        now.accessibilityIdentifier = "tile.updates.now"
        let pause = UIAction(title: paused ? "Resume Updates" : "Pause Updates", image: UIImage(systemName: paused ? "play" : "pause")) {
            [weak self, weak host] _ in
            self?.setPaused(!paused, job: job, pin: pin, accountId: accountId, host: host)
        }
        pause.accessibilityIdentifier = "tile.updates.pause"
        if !writable { now.attributes = .disabled; pause.attributes = .disabled }
        // What runs it and, after a failed run, why it failed: lines to read, not choices.
        var about: [UIMenuElement] = []
        let model = UIAction(title: TileJobs.modelWords(job, botName: botName, botModel: botModel), subtitle: "Updates this tile",
                             image: UIImage(systemName: job.noAgent ? "terminal" : "cpu"), attributes: .disabled) { _ in }
        model.accessibilityIdentifier = "tile.updates.model"
        about.append(model)
        if case .failed(let why) = TileJobs.health(job) {
            let failed = UIAction(title: "Last Update Failed", subtitle: why.map { String($0.prefix(120)) },
                                  image: UIImage(systemName: "exclamationmark.triangle"), attributes: .disabled) { _ in }
            failed.accessibilityIdentifier = "tile.updates.failed"
            about.append(failed)
        }
        let children: [UIMenuElement] = [UIMenu(options: .displayInline, children: about), often,
                                          UIMenu(options: .displayInline, children: [now, pause])]
        if inline { return UIMenu(title: TileJobs.status(job), options: .displayInline, children: children) }
        let menu = UIMenu(title: "Updates", subtitle: TileJobs.status(job), image: UIImage(systemName: "clock.arrow.circlepath"),
                          children: children)
        menu.accessibilityIdentifier = "tile.updates"
        return menu
    }

    private func setFrequency(_ frequency: TileJobs.Frequency, job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?) {
        guard let store = JobsStore.current else { return }
        PagesHaptics.selection()
        Task { [weak self, weak host] in
            let result = await store.update(job, updates: .object(["schedule": .string(frequency.cron)]))
            self?.forget(pin, accountId: accountId)
            guard let host else { return }
            if case .done = result {
                AppLog.trace("pages", "tile updates every \(frequency.minutes) min")
                PagesHUD.show("Updates \(frequency.title)", symbol: "clock.arrow.circlepath", from: host)
            } else {
                AppLog.note("pages", "tile updates change failed: \(result)")
                PagesHUD.show("Couldn’t Change Updates", symbol: "exclamationmark.triangle", from: host)
            }
        }
    }

    private func setPaused(_ pause: Bool, job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?) {
        guard let store = JobsStore.current else { return }
        PagesHaptics.selection()
        Task { [weak self, weak host] in
            let result = await store.setPaused(job, pause)
            self?.forget(pin, accountId: accountId)
            guard let host else { return }
            if result == .done {
                PagesHUD.show(pause ? "Updates Paused" : "Updates Resumed", symbol: pause ? "pause.fill" : "play.fill", from: host)
            } else {
                PagesHUD.show("Couldn’t Change Updates", symbol: "exclamationmark.triangle", from: host)
            }
        }
    }

    private func updateNow(_ job: CronJob, pin: ArtifactPin, accountId: String, host: UIViewController?, redraw: @escaping () -> Void) {
        guard let store = JobsStore.current else { return }
        Haptics.play(.soft)
        if let host { PagesHUD.show("Updating…", symbol: "arrow.clockwise", from: host) }
        Task { [weak self, weak host] in
            let result = await store.runNow(job)
            self?.forget(pin, accountId: accountId)
            switch result {
            case .started, .stillRunning, .alreadyRunning:
                // The job rewrites the file as it ends: the picture is drawn again then (a bot's run takes a while).
                AppLog.trace("pages", "tile update now: \(result)")
                for wait in [20, 60, 180] {
                    try? await Task.sleep(for: .seconds(wait))
                    redraw()
                }
            default:
                AppLog.note("pages", "tile update now failed: \(result)")
                if let host { PagesHUD.show("Couldn’t Update", symbol: "exclamationmark.triangle", from: host) }
            }
        }
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
