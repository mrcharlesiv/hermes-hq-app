// [tile-widgets] The Home Screen widgets' pictures and lists brought up to date while the app is away
// (docs/spec/1x-pages.md §5.8 rule 9):
//   - a background app refresh (`BGAppRefreshTask`, Info.plist's `fetch` mode and permitted identifier), asked for each
//     time the app goes to the background, about every 30 minutes (the system decides when, and whether);
//   - a pushed wake-up (`didReceiveRemoteNotification`): at most once every 10 minutes. The add-on sends none yet; what
//     it would send is in docs/spec/1x-pages.md §5.8 rule 10.
// Both only refresh what a running app can: the system may launch the app for them without a window or a signed-in
// model (SceneDelegate makes the model), and then there is nothing to draw with (REPORT: "Freshness"). In the
// background a tile's picture is never drawn (WebKit draws nothing off screen): the Tile index is brought up to date
// and the pictures wait for the app on screen. The Tasks widget's list is read and written in full either way
// (App/Widgets/TasksWidgetWriter.swift).
// On the Mac, and in an identity without the widget extension, nothing is registered.

#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
import UIKit

@MainActor enum WidgetRefresh {
    /// Info.plist's `BGTaskSchedulerPermittedIdentifiers` lists it.
    nonisolated static let identifier = "ai.hermes.hq.widgets.refresh"
    /// How often the app asks to be woken (the earliest begin date; iOS spaces it as it sees fit).
    nonisolated static let every: TimeInterval = 30 * 60
    /// A pushed wake-up refreshes at most this often.
    nonisolated static let pushedEvery: TimeInterval = 10 * 60

    static var enabled: Bool { TileWidgetWriter.enabled }

    /// Before launch ends (BGTaskScheduler's rule): the handler for the refresh.
    static func register() {
        #if !targetEnvironment(macCatalyst)
        guard enabled else { return }
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { run(task) }
        }
        AppLog.note("widgets", "background refresh \(ok ? "registered" : "not registered")")
        #endif
    }

    /// The app went to the background: the next refresh, about 30 minutes from now.
    static func schedule() {
        #if !targetEnvironment(macCatalyst)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: every)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.trace("widgets", "background refresh asked for in 30 min")
        } catch {
            AppLog.note("widgets", "background refresh not asked for: \((error as NSError).code)")
        }
        #if DEBUG
        debugRefreshInBackground()
        #endif
        #endif
    }

    #if DEBUG && !targetEnvironment(macCatalyst)
    /// `-HQDebugWidgetRefreshInBackground YES`: the background refresh's own work, run 3 s after the app goes to the
    /// background, inside the few seconds iOS gives any app leaving the screen. The simulator can't schedule a
    /// `BGAppRefreshTask` (submit says "unavailable"), so this is how the report shows a picture drawn while the app is
    /// in the background.
    private static func debugRefreshInBackground() {
        guard UserDefaults.standard.bool(forKey: "HQDebugWidgetRefreshInBackground") else { return }
        let time = BackgroundTime.begin("widgets.debug-refresh") {
            AppLog.note("widgets", "debug background refresh: out of time")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let outcome = await refresh(reason: "debug background refresh")
            AppLog.note("widgets", "debug background refresh: \(outcome), remaining \(Int(min(UIApplication.shared.backgroundTimeRemaining, 9_999))) s")
            time.end()
        }
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    private static func run(_ task: BGTask) {
        schedule()   // the next one, whatever this one does
        let work = Task { @MainActor in
            let outcome = await refresh(reason: "background refresh")
            task.setTaskCompleted(success: outcome != .failed)
        }
        task.expirationHandler = {
            AppLog.note("widgets", "background refresh: out of time")
            work.cancel()
        }
    }
    #endif

    enum Outcome: Equatable { case changed, unchanged, failed }

    /// When a pushed wake-up last refreshed (this run).
    private static var lastPushed: Date?

    /// A push woke the app: a refresh, unless one ran in the last 10 minutes.
    static func pushed(_ done: @escaping (UIBackgroundFetchResult) -> Void) {
        guard enabled else { return done(.noData) }
        let now = Date()
        guard shouldRunPushed(last: lastPushed, now: now) else {
            AppLog.trace("widgets", "pushed refresh skipped: one ran in the last 10 min")
            return done(.noData)
        }
        lastPushed = now
        Task { @MainActor in
            switch await refresh(reason: "pushed refresh") {
            case .changed: done(.newData)
            case .unchanged: done(.noData)
            case .failed: done(.failed)
            }
        }
    }

    /// The push throttle: a first push runs, then one every 10 minutes.
    nonisolated static func shouldRunPushed(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= pushedEvery || now < last
    }

    /// Everything the widgets show, brought up to date by what this process holds. Logged with what it could do.
    /// Also renews any saved Nous session that has sat untouched for ≥ 4 h so Portal's 24 h rotating refresh token
    /// never lapses while the app stays in the background.
    static func refresh(reason: String) async -> Outcome {
        let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
        let window = UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.windows.isEmpty == false }
        let keptAlive = await NousSessionKeepAlive.refreshDue(vault: .app)
        guard TileWidgetWriter.shared.accountKey != nil else {
            if keptAlive > 0 {
                AppLog.note("widgets", "\(reason) (\(state)): renewed \(keptAlive) Nous session(s) with no window")
                return .unchanged
            }
            AppLog.note("widgets", "\(reason) (\(state)): nobody signed in in this launch, nothing to refresh")
            return .failed
        }
        let drawing = state == "foreground"
        AppLog.note("widgets", "\(reason) (\(state), \(window ? "window" : "no window")): started"
                    + (drawing ? "" : ", the index alone (pictures wait for the app on screen)"))
        let tiles = await TileWidgetWriter.shared.refreshAll(drawing: drawing)
        // [tasks-widget] The Tasks list read and written in full: one small request, no web view, so in the background too.
        let tasks = await TasksWidgetWriter.shared.refresh()
        AppLog.note("widgets", "\(reason): \(tiles ? "tiles changed" : "tiles unchanged"), \(tasks ? "tasks changed" : "tasks unchanged")")
        return tiles || tasks ? .changed : .unchanged
    }
}
