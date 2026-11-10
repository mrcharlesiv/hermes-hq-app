// A job's actions as every entry point runs them (docs/spec/1x-pages.md §3.6): Run Now always asks ("Run “…” Now?"),
// Pause / Resume don't, Delete asks "Delete Job?". Results: the "Run Started" HUD, "Still Running on Your Gateway",
// alerts with Try Again for failures, "Changes are off for this gateway." when read-only.

import UIKit

@MainActor
final class JobActions {
    let store: JobsStore
    /// Called after a delete succeeds (the detail pops).
    var onDeleted: ((CronJob) -> Void)?
    // [jobs] The editor's entry points (docs/spec/3x-jobs.md §4.5): the bots it can offer, the page's bot, and what
    // the list does once a job was made (scrolls it into view).
    weak var services: PagesServices?
    var currentScope: (() -> String)?
    var onCreated: ((String?) -> Void)?
    private weak var openEditor: UIViewController?

    init(store: JobsStore) { self.store = store }

    func runCopy(_ job: CronJob) -> (title: String, description: String) {
        let copy = JobWords.runNowCopy(store.title(job), deliver: job.deliver ?? "local", origin: job.origin,
                                       names: JobWords.knownChatNames(store.jobs))
        return (JobWords.runAlertTitle(copy.title), copy.description)
    }

    private func refusedNotice(_ from: UIViewController) {
        PagesHUD.show(JobsStore.readOnlyNotice, symbol: "lock", from: from, duration: 2.5)
        PagesHaptics.error()
    }

    /// Where an action's result goes, captured when it is tapped: the tab bar controller (else the window's root), so a
    /// page left while the request runs (a run answers only when it ends, up to 120 s) still gets its HUD and alert.
    static func resultHost(for controller: UIViewController) -> UIViewController {
        controller.tabBarController ?? controller.view.window?.rootViewController ?? controller
    }

    /// The view controller an alert can be presented from now: the window's topmost presented controller.
    static func topmost(_ host: UIViewController) -> UIViewController {
        var top = host.view.window?.rootViewController ?? host
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: Run Now

    func runNow(_ job: CronJob, from controller: UIViewController) {
        if store.readOnlyGateway { refusedNotice(controller); return }
        let copy = runCopy(job)
        let alert = UIAlertController(title: copy.title, message: copy.description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let host = Self.resultHost(for: controller)
        let run = UIAlertAction(title: "Run", style: .default) { [weak self] _ in
            guard let self else { return }
            Task { await self.performRun(job, host: host) }
        }
        alert.addAction(run)
        alert.preferredAction = run
        alert.view.accessibilityIdentifier = "jobs.run-alert"
        Self.topmost(controller).present(alert, animated: true)
    }

    private func performRun(_ job: CronJob, host: UIViewController) async {
        // [live] Running on the Lock Screen and in the Dynamic Island from now until a Jobs read says it is over.
        let live = LiveActivityCenter.shared
        live.jobRunStarted(job, title: store.title(job), botName: botName(job), store: store)
        let result = await store.runNow(job)
        live.jobRunAnswered(job.key, result)
        switch result {
        case .started:
            PagesHaptics.success()
            PagesHUD.show("Run Started", symbol: "bolt.fill", from: host)
        case .stillRunning:
            PagesHaptics.success()   // it started; the answer only took longer than the wait
            PagesHUD.show("Still Running on Your Gateway", symbol: "clock", from: host, duration: 2.5)
        case .refused:
            refusedNotice(host)
        case .alreadyRunning(let reason):
            PagesHaptics.error()
            failure("Couldn’t Run Job", reason, host: host, retry: nil)
        case .restorePauseFailed:
            // The warning that a paused job may now fire on its schedule: it must be seen wherever the user went.
            PagesHaptics.error()
            failure("Couldn’t Restore Pause", "Couldn’t restore the job’s paused state after running. Check its schedule.",
                    host: host, retry: nil)
        case .failed(let reason):
            PagesHaptics.error()
            failure("Couldn’t Run Job", reason, host: host) { [weak self] in
                guard let self else { return }
                // A failed run may have started: Try Again asks again (R13).
                self.runNow(self.store.job(key: job.key) ?? job, from: host)
            }
        }
    }

    /// The bot that owns the job, by its name ("Hermes" for default), else the profile as written.
    private func botName(_ job: CronJob) -> String {
        services?.bots.first { $0.id == job.owner }?.name ?? (job.owner == "default" ? "Hermes" : job.owner)
    }

    // MARK: Pause / Resume

    func togglePause(_ job: CronJob, from controller: UIViewController) {
        if store.readOnlyGateway { refusedNotice(controller); return }
        let pause = !Self.isPaused(job)
        let host = Self.resultHost(for: controller)
        Task {
            switch await store.setPaused(job, pause) {
            case .done: PagesHaptics.success()
            case .refused: refusedNotice(host)
            case .failed(let reason):
                PagesHaptics.error()
                failure(pause ? "Couldn’t Pause Job" : "Couldn’t Resume Job", reason, host: host) {
                    self.togglePause(self.store.job(key: job.key) ?? job, from: host)
                }
            }
        }
    }

    static func isPaused(_ job: CronJob) -> Bool {
        let state = JobWords.jobState(job)
        return state == "paused" || state == "disabled" || job.enabled == false
    }

    // MARK: Delete

    /// "Delete Job?": an action sheet anchored to the control (`source`), an alert on the detail page.
    func delete(_ job: CronJob, from controller: UIViewController, source: UIView? = nil, sourceRect: CGRect? = nil,
                style: UIAlertController.Style = .actionSheet) {
        if store.readOnlyGateway { refusedNotice(controller); return }
        let title = store.title(job)
        let sheet = UIAlertController(title: "Delete Job?",
                                      message: "This will remove “\(title)” permanently. It will stop firing immediately.",
                                      preferredStyle: style)
        let host = Self.resultHost(for: controller)
        sheet.addAction(UIAlertAction(title: "Delete Job", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                switch await self.store.delete(job) {
                case .done:
                    PagesHaptics.success()
                    self.onDeleted?(job)
                case .refused: self.refusedNotice(host)
                case .failed(let reason):
                    PagesHaptics.error()
                    self.failure("Couldn’t Delete Job", reason, host: host) {
                        self.delete(job, from: host, style: .alert)
                    }
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? controller.view
            popover.sourceRect = sourceRect ?? source?.bounds ?? CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        }
        Self.topmost(controller).present(sheet, animated: true)
    }

    // MARK: New Job, Edit Job  [jobs]

    private func editorBots() -> [(id: String, name: String)] {
        PagesNames.scopeChoices(services?.bots ?? []).map { (id: $0.id, name: $0.name) }
    }

    /// One editor at a time, never over another sheet or alert.
    private func present(_ model: JobEditorModel, from controller: UIViewController) {
        let presenter = Self.topmost(controller)
        guard openEditor?.presentingViewController == nil, !(presenter is UIAlertController), !presenter.isBeingDismissed else { return }
        let host = Self.resultHost(for: controller)
        let bots = services?.bots ?? []
        let sheet = JobEditorSheet.make(model: model, head: { PagesNames.head($0, bots: bots) }) { [weak self] outcome in
            switch outcome {
            case .created(let key):
                PagesHaptics.success()
                PagesHUD.show("Job Created", symbol: "checkmark", from: host)
                self?.onCreated?(key)
                // Run Once Now: the first run starts at once, with Run Now's own answers (Run Started, a refusal). The
                // gateway's answer stands in when the list read after it lacks the job (audit 863: another bot than the
                // page shows, or a failed read, skipped the run unsaid).
                if model.form.runNow, let self {
                    if let job = key.flatMap({ self.store.job(key: $0) }) ?? model.created {
                        Task { await self.performRun(job, host: host) }
                    } else {
                        PagesHaptics.error()
                        self.failure("Couldn’t Start the First Run", "The job was made. Run it from its page with Run Now.",
                                     host: host, retry: nil)
                    }
                }
            case .saved:
                PagesHaptics.success()
                PagesHUD.show("Job Saved", symbol: "checkmark", from: host)
            case .failed:
                break
            }
        }
        openEditor = sheet
        presenter.present(sheet, animated: true)
    }

    /// New Job, for the page's bot (the first bot under All Bots), optionally starting from a blueprint.
    func newJob(from controller: UIViewController, blueprint: Blueprint? = nil) {
        if store.readOnlyGateway { refusedNotice(controller); return }
        let bots = editorBots()
        let scope = currentScope?() ?? store.scope
        let profile = blueprint != nil ? store.listProfile : (scope == PagesScope.all ? (bots.first?.id ?? "default") : scope)
        present(JobEditorModel(store: store, mode: .create, bots: bots, profile: profile, blueprint: blueprint), from: controller)
    }

    func edit(_ job: CronJob, from controller: UIViewController) {
        if store.readOnlyGateway { refusedNotice(controller); return }
        let current = store.job(key: job.key) ?? job
        present(JobEditorModel(store: store, mode: .edit(current), bots: editorBots(), profile: current.owner), from: controller)
    }

    // MARK: Failure alert

    /// A failed action's alert, from the window's topmost controller (the page that started it may be gone).
    func failure(_ title: String, _ reason: String, host: UIViewController, retry: (() -> Void)?) {
        let alert = UIAlertController(title: title, message: reason, preferredStyle: .alert)
        if let retry { alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in retry() }) }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        Self.topmost(host).present(alert, animated: true)
    }

    // MARK: Menus

    /// Run Now, Pause/Resume, Edit Job…, then Delete Job in its own section (docs/spec/3x-jobs.md §6.2).
    func menu(_ job: CronJob, from controller: UIViewController, source: @escaping () -> UIView?) -> UIMenu {
        let busy = store.isBusy(job)
        let run = UIAction(title: "Run Now", image: UIImage(systemName: "bolt"), attributes: busy ? .disabled : []) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.runNow(job, from: controller)
        }
        let paused = Self.isPaused(job)
        let toggle = UIAction(title: paused ? "Resume" : "Pause", image: UIImage(systemName: paused ? "play" : "pause"),
                              attributes: busy ? .disabled : []) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.togglePause(job, from: controller)
        }
        let edit = UIAction(title: "Edit Job…", image: UIImage(systemName: "pencil"), attributes: busy ? .disabled : []) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.edit(self.store.job(key: job.key) ?? job, from: controller)
        }
        let delete = UIAction(title: "Delete Job", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.delete(job, from: controller, source: source())
        }
        return UIMenu(children: [run, toggle, edit, UIMenu(options: .displayInline, children: [delete])])
    }
}
