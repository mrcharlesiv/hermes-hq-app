// DEBUG-only launch hooks for the pages' screenshots and probes (compiled out of Release). Launch arguments:
//
// - `-HQPagesTab <n>`            select tab n (2 Jobs, 3 Kanban/Artifacts, 4 More) once the app is up
// - `-HQPagesOpenJob <id>`       …and push that job's detail (Jobs)
// - `-HQPagesNewJob YES|<key>`   …and open New Job (a blueprint key starts from that blueprint)
// - `-HQPagesEditJob <id>`       …and open Edit Job for that job
// - `-HQPagesJobScroll <where>`  …and scroll the job editor (`when`, `deliver`, `end`)
// - `-HQPagesOpenTask <title>`   …and open the Kanban task (or, on Tasks, the task) with that title
// - `-HQPagesTaskChat YES|<words>` …and open that task's own chat over it (Tasks), sending the words if given
// - `-HQPagesTaskPage YES`       …and open that task's Task Page (Tasks)
// - `-HQPagesNewTask YES`        …and open New Task (Kanban's, or Tasks')
// - `-HQPagesTasksSettings YES`  …and open Tasks Settings (on Tasks)
// - `-HQPagesTasksIdeas YES`     …and show Tasks' Inbox (the bot's ideas are at its foot)
// - `-HQPagesTasksView <key>`    …and show that Tasks view (today, upcoming, inbox, bots, or a list by its name)
// - `-HQPagesImportReminders N`  …and add N reminders to Reminders (0 adds none), then tap Import from Reminders (on Tasks)
// - `-HQPagesChip <status>`      …and pick that Kanban chip
// - `-HQPagesFilter <kind>`      …and pick that Artifacts segment (image, file, link)
// - `-HQPagesMore <row id>`      …and open that More row
// - `-HQPagesOpenArtifact <label>` …and open that artifact (Artifacts, wherever it lives)
// - `-HQPagesReadOnly YES`       refuse every page write, as a read-only gateway does (PagesTabs)
// - `-HQPagesOpenSession <id>`   open that stored chat as a tapped alert does (NotificationHub.open), 4 s after the tabs show

#if DEBUG
import UIKit

@MainActor
enum PagesDebug {
    private static var defaults: UserDefaults { .standard }

    static func apply(_ pages: PagesTabs, host: UITabBarController) {
        if let stored = defaults.string(forKey: "HQPagesOpenSession") {
            Task { @MainActor in
                // Once signed in and on screen (a sign-in from the launch's environment comes late on the Mac).
                for _ in 0..<60 where MainTabController.current?.view.window == nil { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(4))
                NotificationHub.shared.open(stored, profile: nil)
            }
        }
        guard let tab = defaults.object(forKey: "HQPagesTab") as? Int ?? Int(defaults.string(forKey: "HQPagesTab") ?? "") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showTab(tab, host: host, tries: 20) }
    }

    /// [taborder] n is the tab's tag (`HQTab`), its place only in the default order. [mac] A plugin page's place (1000
    /// on) comes once its bots' pages are read: tried again for up to 10 s.
    private static func showTab(_ tab: Int, host: UITabBarController, tries: Int) {
        guard let main = host as? MainTabController else { return }
        guard let place = main.placedTab(tagged: tab) else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showTab(tab, host: host, tries: tries - 1) } }
            return
        }
        main.show(place)
        guard let nav = host.selectedViewController as? UINavigationController else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { follow(nav) }
    }

    private static func follow(_ nav: UINavigationController) {
        if let id = defaults.string(forKey: "HQPagesMore"), let more = nav.topViewController as? MoreViewController {
            more.open(rowId: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { follow(nav) }
            return
        }
        let top = nav.topViewController
        if let jobs = top as? JobsViewController, let id = defaults.string(forKey: "HQPagesOpenJob"),
           let job = jobs.store.jobs.first(where: { $0.id == id }) {
            jobs.openDetail(job.key)
        }
        if let jobs = top as? JobsViewController, let new = defaults.string(forKey: "HQPagesNewJob") {
            let blueprint = jobs.store.blueprintsByProfile.values.joined().first { $0.key == new }
            jobs.actions.newJob(from: jobs, blueprint: blueprint)
        }
        if let jobs = top as? JobsViewController, let id = defaults.string(forKey: "HQPagesEditJob"),
           let job = jobs.store.jobs.first(where: { $0.id == id }) {
            jobs.actions.edit(job, from: jobs)
        }
        if let kanban = top as? KanbanViewController {
            if let chip = defaults.string(forKey: "HQPagesChip") { kanban.store.picked(chip); kanban.reload(animated: false) }
            if let title = defaults.string(forKey: "HQPagesOpenTask"), let task = kanban.store.board?.allTasks.first(where: { $0.title == title }) {
                kanban.openTask(task.id)
            }
            if defaults.bool(forKey: "HQPagesNewTask") { kanban.newTask() }
        }
        // [tasks] The Tasks page (More › Tasks, or its own tab): waits for the list to load.
        if let tasks = top as? TasksViewController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let title = defaults.string(forKey: "HQPagesOpenTask"), let task = tasks.store.tasks.first(where: { $0.title == title }) {
                    let words = defaults.string(forKey: "HQPagesTaskChat")
                    tasks.openTask(task.id, asking: words == "YES" ? "" : words)
                    if defaults.bool(forKey: "HQPagesTaskPage") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { TodoSheetModel.debugLast?.openPage() }
                    }
                }
                if defaults.bool(forKey: "HQPagesNewTask") { tasks.newTask() }
                if defaults.bool(forKey: "HQPagesTasksIdeas") { tasks.showIdeas() }
                if let key = defaults.string(forKey: "HQPagesTasksView") {
                    if let view = TodoView(key: key), !key.hasPrefix("list:") { tasks.show(view) }
                    else if let list = tasks.store.sections.first(where: { $0.name == key }) { tasks.show(.list(list.id)) }
                }
                if defaults.bool(forKey: "HQPagesTasksSettings") { tasks.openSettings() }
                if let count = defaults.string(forKey: "HQPagesImportReminders").flatMap(Int.init) {
                    Task {
                        await TodoRemindersImport.seedForDebug(count)
                        tasks.importReminders()
                    }
                }
            }
        }
        if let artifacts = top as? ArtifactsViewController {
            if let kind = defaults.string(forKey: "HQPagesFilter") { artifacts.select(filter: ArtifactRecord.Kind(rawValue: kind)) }
            if let label = defaults.string(forKey: "HQPagesOpenArtifact") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let record = artifacts.store.artifacts.first(where: { $0.label == label }) { artifacts.open(record) }
                }
            }
        }
    }
}

#endif
