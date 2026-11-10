// [live] The Lock Screen and Dynamic Island progress for a long bot turn or a job run from Jobs (docs/spec/3x-presence.md
// §17, docs/spec/3x-jobs.md §12). `LiveActivityPlanner` (HermesKit/Live) decides; this hands its commands to ActivityKit
// through `LiveActivityDriver`, a seam the unit tests fill with a recorder.
//
// Shown only in a build that carries the widget extension (HermesHQTalkActivity — the same one that already draws
// Talk's own Live Activity, docs/spec/3x-talk-background.md, embedded only in the original identity's build). Reusing
// it is the point: no App ID of its own, nothing to turn on. Without that extension — the native identity's build, and
// the Mac — `isOffered` is false: nothing starts and Settings shows no switch.
//
// Updates come from the app itself: while it runs, and in the background time it already has (the socket's 20 s grace,
// `BackgroundTaskHolder`). A turn's activity can also be ended sooner by NotificationService (best effort, on the add-on's
// "reply finished" push — see NotificationService.swift); short of that, once iOS suspends the app, the activity's clock
// keeps counting by itself until the next return (or the next Jobs read) ends it, or for 30 minutes without news, when
// it goes stale and stops counting (ReplyActivityWidget's `LiveElapsed`).
//
// [live-steps] A turn's card names the step its bot is on (owner, 2026-10-31: "it needs to show the live tool calls"),
// from `Bot.step` while the app runs. Once iOS suspends the app only a push can change the card, so a turn's activity
// asks iOS for a push token and hands it to the gateway's add-on (hermes-hq-push 0.9.22+, `liveSteps`, through
// PushRegistrar), which pushes each new step sealed with this phone's key and ends the card Done when the turn ends.

import Foundation
import UIKit
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor protocol LiveActivityDriver: AnyObject {
    /// This build carries the widget extension (Settings shows the switch).
    var isOffered: Bool { get }
    /// iOS lets this app show them (Settings › Hermes HQ › Live Activities).
    var isAllowed: Bool { get }
    /// False when iOS refused it.
    func start(_ start: LiveActivityStart) -> Bool
    /// [live-steps] Called with each push token iOS gives a turn's activity (its activity id, the token in hex).
    var onPushToken: (@MainActor (LiveActivitySubject, String, String) -> Void)? { get set }
    func update(_ subject: LiveActivitySubject, _ content: LiveActivityContent)
    func end(_ subject: LiveActivitySubject, _ content: LiveActivityContent?, _ dismissal: LiveActivityDismissal)
    /// Ends what an earlier run of the app left on show (it can no longer follow them).
    func endLeftovers()
    /// The person is back in the app: every card that is already over (Done or Failed, lingering on the Lock Screen)
    /// goes now. The app shows the result itself, and a lingering Done reads as the answer to the next message.
    func clearFinished()
}

@MainActor final class LiveActivityCenter {
    static let shared = LiveActivityCenter(driver: LiveActivityCenter.systemDriver(), steps: PushRegistrar.shared)

    /// `-HQDebugLiveReset YES` (Debug builds): a UI test starts from the default (on), whatever an earlier test left.
    private static let debugReset: Void = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugLiveReset") { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        #endif
    }()

    /// Settings › Notifications › Show Progress on Lock Screen. Absent = on.
    nonisolated static let defaultsKey = "hq.liveActivities"
    static var isOn: Bool {
        get {
            _ = debugReset
            return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        }
        set {
            if newValue { UserDefaults.standard.removeObject(forKey: defaultsKey) }
            else { UserDefaults.standard.set(false, forKey: defaultsKey) }
        }
    }

    let driver: any LiveActivityDriver
    private(set) var planner: LiveActivityPlanner
    var now: () -> Date = Date.init
    var appActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    /// The stored id of the chat a live voice conversation runs in (its own card covers that chat's turn).
    var talkingSession: () -> String? = { TalkController.shared.liveStoredSessionId }
    /// [live-steps] Where a turn's push token goes (PushRegistrar.shared; tests record).
    var steps: (any LiveStepsRelay)?
    /// [live-steps] Subject → the activity id its push token was handed over under, so its end withdraws it.
    private var handedOver: [LiveActivitySubject: String] = [:]
    private var lastBots: [LiveBot] = []
    /// [live-chats] The bots' other chats running a turn (`sideChatsChanged`).
    private var lastSideChats: [LiveBot] = []
    /// Every chat the rules follow: the Bot Chats, then the side chats.
    private var chats: [LiveBot] { lastBots + lastSideChats }
    private var leftoversCleared = false
    private weak var jobs: JobsStore?

    init(driver: any LiveActivityDriver, enabled: Bool = LiveActivityCenter.isOn, steps: (any LiveStepsRelay)? = nil) {
        self.driver = driver
        self.steps = steps
        planner = LiveActivityPlanner(enabled: enabled, available: driver.isOffered)
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "HQDebugLiveThreshold")   // a launch argument is a string; this reads it
        if seconds > 0 { planner.turnThreshold = seconds }
        #endif
        self.driver.onPushToken = { [weak self] subject, activity, token in self?.pushToken(subject, activity: activity, token: token) }
    }

    /// Settings shows the switch.
    var isOffered: Bool { driver.isOffered }

    func setOn(_ on: Bool) {
        Self.isOn = on
        run(planner.setEnabled(on))
    }

    // MARK: Turns

    func botsChanged(_ bots: [Bot]) {
        lastBots = bots.map { bot in
            LiveBot(id: bot.id, name: bot.name, isWorking: bot.isWorking, link: bot.canonicalSessionId.map(Self.sessionLink),
                    step: bot.isWorking ? bot.step : nil, session: bot.canonicalSessionId)
        }
        run(planner.bots(chats, now: now(), appActive: appActive()))
    }

    /// [live-chats] The bots' other chats running a turn now (AppModel, from BotStore.busySideChats): each gets a card
    /// of its own when the app is left, "Otto · Day check", and ends Done when its turn does. Before, only a Bot Chat's
    /// turn had one (a tester, 2026-11-05: a reply in a chat started from Sessions never showed).
    func sideChatsChanged(_ sideChats: [LiveBot]) {
        guard sideChats != lastSideChats else { return }
        lastSideChats = sideChats
        run(planner.bots(chats, now: now(), appActive: appActive()))
    }

    /// `sceneWillResignActive`: the last moment iOS lets the app start one.
    func appLeaving() {
        planner.available = driver.isOffered && driver.isAllowed
        let commands = planner.leaving(chats, now: now(), talking: talkingSession())
        let working = chats.filter(\.isWorking).count
        if working > 0 {
            let side = lastSideChats.filter(\.isWorking).count
            AppLog.note("live", "leaving: \(working) working (\(side) side chats), \(commands.count) to start (on \(planner.enabled), offered \(driver.isOffered), allowed \(driver.isAllowed))")
        }
        run(commands)
    }

    /// `sceneDidBecomeActive`. The first one ends what an earlier run left on show; every one takes away the cards
    /// that are over and asks the followed jobs again (a Jobs read may not come while the Jobs page is off screen).
    /// The bots' first read after a return can land before iOS calls the app active, and a turn it finds over then
    /// ends Done to linger 15 min as if the person were still away (owner, 2026-11-01: sent Hermes a message, locked
    /// the phone, and the card "just said done": the reply before's). Clearing here catches it whatever the order.
    func appBecameActive() {
        if !leftoversCleared {
            leftoversCleared = true
            driver.endLeftovers()
        }
        driver.clearFinished()
        if let jobs, !planner.followedJobs.isEmpty { Task { await jobs.refresh(background: true) } }
    }

    // MARK: Jobs

    /// Run Now was confirmed (JobActions): Running, until a Jobs read says it is over.
    func jobRunStarted(_ job: CronJob, title: String, botName: String, store: JobsStore?) {
        if let store { follow(store) }
        run(planner.jobStarted(key: job.key, title: title, botName: botName, link: Self.jobLink(job.key), now: now()))
    }

    func jobRunAnswered(_ key: String, _ result: JobsStore.RunResult) {
        let answer: LiveRunAnswer
        switch result {
        case .started, .stillRunning, .restorePauseFailed: answer = .answered
        case .refused, .alreadyRunning: answer = .notStarted
        case .failed: answer = .failed
        }
        run(planner.jobAnswered(key: key, answer, now: now(), appActive: appActive()))
    }

    private func follow(_ store: JobsStore) {
        guard jobs !== store else { return }
        jobs = store
        store.onListRead = { [weak self, weak store] in
            guard let self, let store else { return }
            self.jobsRead(store)
        }
    }

    func jobsRead(_ store: JobsStore) {
        var states: [String: LiveJobState] = [:]
        for key in planner.followedJobs {
            guard let job = store.job(key: key) else { states[key] = .gone; continue }
            states[key] = Self.state(of: job, inFlight: store.showsRunning(job))
        }
        jobsStates(states)
    }

    /// Each followed job's state after a read (keys left out are gone from the list).
    func jobsStates(_ states: [String: LiveJobState]) {
        run(planner.jobs(states, now: now(), appActive: appActive()))
    }

    nonisolated static func state(of job: CronJob, inFlight: Bool) -> LiveJobState {
        if inFlight || JobWords.isRunning(job) { return .running }
        return JobWords.lastRunFailed(job) ? .failed : .done
    }

    // MARK: Pushed steps

    /// [live-steps] iOS gave a turn's activity a push token (and gives a new one if it changes): the add-on gets it with
    /// the turn's start and what the card already says, so its pushes carry on from there.
    private func pushToken(_ subject: LiveActivitySubject, activity: String, token: String) {
        guard subject.kind == .turn, let shown = planner.live[subject], let steps else { return }
        handedOver[subject] = activity
        let chat = chats.first(where: { $0.id == subject.id })
        let start = LiveStepsHandOver(activity: activity, token: token, profile: chat?.botProfile ?? subject.id, session: chat?.session,
                                      startedAt: shown.content.startedAt, trail: shown.content.trail)
        Task { await steps.handOverSteps(start) }
    }

    // MARK: Sign-out

    /// The account's stores went (sign-out, a gateway switch, an ended session): nothing of it stays on show.
    func accountLeft() {
        lastBots = []
        lastSideChats = []
        jobs?.onListRead = nil
        jobs = nil
        run(planner.endAll())
    }

    // MARK: Links

    /// `<scheme>://session/<stored id>`: the app's own link handling opens that chat.
    static func sessionLink(_ stored: String) -> String { "\(AppIdentity.current.urlScheme)://session/\(stored)" }

    /// `<scheme>://job/<owner%7Cid>`: Jobs, on that job's page (AppDelegate's link handling, `DeepLink.other`).
    static func jobLink(_ key: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/|")
        return key.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(AppIdentity.current.urlScheme)://job/\($0)" }
    }

    // MARK: Commands

    private func run(_ commands: [LiveActivityCommand]) {
        for command in commands {
            switch command {
            case .start(let start):
                if driver.start(start) {
                    AppLog.note("live", "start \(start.subject.kind.rawValue)")
                } else {
                    planner.startFailed(start.subject)
                }
            case .update(let subject, let content):
                driver.update(subject, content)
            case .end(let subject, let content, let dismissal):
                AppLog.note("live", "end \(subject.kind.rawValue) \(content?.phase.rawValue ?? "removed")")
                if let activity = handedOver.removeValue(forKey: subject), let steps {
                    Task { await steps.withdrawSteps(activity) }      // [live-steps] the add-on stops pushing to it
                }
                #if DEBUG
                lastEnd = "\(subject.kind.rawValue):\(subject.id)=\(content?.phase.rawValue ?? "removed")"
                #endif
                driver.end(subject, content, dismissal)
            }
        }
        #if DEBUG
        showProbe()
        #endif
    }

    #if DEBUG
    /// `-HQDebugLiveProbe YES`: a one-point element "debug.live" whose value lists what is on show
    /// ("job:deploys|j-watch=running turn:default=working", "none"), so a UI test can tell an activity started and ended.
    private weak var probeView: UIView?
    /// The last one that ended and how ("job:deploys|j-watch=done"): the probe's label.
    private var lastEnd: String?

    func showProbe() {
        guard UserDefaults.standard.bool(forKey: "HQDebugLiveProbe") else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return }
        let view = probeView ?? {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.live"
            probeView = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        let shown = planner.live.values.sorted { $0.subject.id < $1.subject.id }
            .map { "\($0.subject.kind.rawValue):\($0.subject.id)=\($0.content.phase.rawValue)" }
        view.accessibilityValue = shown.isEmpty ? "none" : shown.joined(separator: " ")
        view.accessibilityLabel = lastEnd ?? ""
    }
    #endif

    // MARK: The system's driver

    static func systemDriver() -> any LiveActivityDriver {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return ActivityKitDriver()
        #else
        return NoLiveActivities()
        #endif
    }
}

/// The Mac, and any build without ActivityKit: nothing is offered.
@MainActor final class NoLiveActivities: LiveActivityDriver {
    var isOffered: Bool { false }
    var isAllowed: Bool { false }
    var onPushToken: (@MainActor (LiveActivitySubject, String, String) -> Void)?
    func start(_ start: LiveActivityStart) -> Bool { false }
    func update(_ subject: LiveActivitySubject, _ content: LiveActivityContent) {}
    func end(_ subject: LiveActivitySubject, _ content: LiveActivityContent?, _ dismissal: LiveActivityDismissal) {}
    func endLeftovers() {}
    func clearFinished() {}
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
@MainActor final class ActivityKitDriver: LiveActivityDriver {
    /// Subject → its activity's id. The activities themselves are looked up by id where they are used (off the main
    /// actor), so none is shared across isolation.
    private var ids: [LiveActivitySubject: String] = [:]
    /// The last change handed to ActivityKit: each waits for the one before, so an end that lingers and the return's
    /// clear-out that follows it reach the card in that order.
    private var last: Task<Void, Never>?
    /// [live-steps] Whether a turn's activity asks for a push token (the add-on pushes its steps): the build can get
    /// pushes at all (PushRegistrar.available — the original identity).
    var wantsPushTokens: () -> Bool = { PushRegistrar.available }
    var onPushToken: (@MainActor (LiveActivitySubject, String, String) -> Void)?

    var isOffered: Bool { LiveActivityBuild.extensionEmbedded }
    var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(_ start: LiveActivityStart) -> Bool {
        let attributes = HQLiveAttributes(subject: start.subject, botName: start.botName, detail: start.detail, link: start.link,
                                          accent: HQPalette.cardAccent)
        let content = ActivityContent(state: start.content, staleDate: LiveActivityPlanner.staleDate(start.content, now: Date()))
        let pushed = start.subject.kind == .turn && wantsPushTokens()
        do {
            let activity: Activity<HQLiveAttributes>
            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: pushed ? .token : nil)
            } catch where pushed {
                // [live-steps] A build or phone that can't take its pushes still shows the card the app updates.
                AppLog.note("live", "start with push refused (\(error.localizedDescription)): without")
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            }
            ids[start.subject] = activity.id
            if pushed { follow(activity.id, start.subject) }
            return true
        } catch {
            AppLog.note("live", "start refused: \(error.localizedDescription)")
            return false
        }
    }

    /// [live-steps] Each push token iOS gives the activity (it can change while it shows) goes to `onPushToken`.
    private func follow(_ id: String, _ subject: LiveActivitySubject) {
        let report: @MainActor @Sendable (String) -> Void = { [weak self] token in
            guard let self, self.ids[subject] == id else { return }
            self.onPushToken?(subject, id, token)
        }
        Task { await Self.pushTokens(id: id, report) }
    }

    @concurrent private nonisolated static func pushTokens(id: String, _ report: @escaping @MainActor @Sendable (String) -> Void) async {
        guard let activity = Activity<HQLiveAttributes>.activities.first(where: { $0.id == id }) else { return }
        for await data in activity.pushTokenUpdates {
            let token = data.map { String(format: "%02x", $0) }.joined()
            await report(token)
        }
    }

    func update(_ subject: LiveActivitySubject, _ content: LiveActivityContent) {
        guard let id = ids[subject] else { return }
        then { await Self.update(id: id, content) }
    }

    func end(_ subject: LiveActivitySubject, _ content: LiveActivityContent?, _ dismissal: LiveActivityDismissal) {
        guard let id = ids.removeValue(forKey: subject) else { return }
        // A turn can end in the socket's background grace: the end gets its own time, given back once it is sent.
        let time = BackgroundTime.begin("Hermes HQ Live Activity")
        then {
            await Self.end(id: id, content, dismissal)
            time.end()
        }
    }

    func endLeftovers() {
        let known = Set(ids.values)
        then { await Self.endAll(except: known) }
    }

    func clearFinished() {
        then { await Self.clearFinished() }
    }

    private func then(_ change: @escaping @MainActor () async -> Void) {
        let before = last
        last = Task {
            await before?.value
            await change()
        }
    }

    @concurrent private nonisolated static func update(id: String, _ content: LiveActivityContent) async {
        guard let activity = Activity<HQLiveAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: content, staleDate: LiveActivityPlanner.staleDate(content, now: Date())))
    }

    @concurrent private nonisolated static func end(id: String, _ content: LiveActivityContent?, _ dismissal: LiveActivityDismissal) async {
        guard let activity = Activity<HQLiveAttributes>.activities.first(where: { $0.id == id }) else {
            AppLog.note("live", "end: the card was already gone")
            return
        }
        AppLog.note("live", "end: the card was \(described(activity))")
        let policy: ActivityUIDismissalPolicy
        switch dismissal {
        case .immediate: policy = .immediate
        case .after(let date): policy = .after(date)
        }
        // The add-on's push ended it first: its words stay (they say when the reply really ended, not when the app heard).
        let over = activity.activityState == .ended
        await activity.end(over ? nil : content.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: policy)
    }

    @concurrent private nonisolated static func clearFinished() async {
        for activity in Activity<HQLiveAttributes>.activities where activity.activityState == .ended || activity.content.state.isOver {
            AppLog.note("live", "clear \(activity.attributes.subject.kind.rawValue): the card was \(described(activity))")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @concurrent private nonisolated static func endAll(except known: Set<String>) async {
        for activity in Activity<HQLiveAttributes>.activities where !known.contains(activity.id) {
            AppLog.note("live", "end leftover \(activity.attributes.subject.kind.rawValue): the card was \(described(activity))")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// [live] How a card stood when the app came to end it ("active, working, 18 min, last change by the app"; "ended,
    /// done, 4 min, last change pushed"): whether the add-on's pushes (its steps, its end) reached it while the app was
    /// away, and whether NotificationService's try at ending one ever finds it (owner, 2026-11-01: a long turn's clock
    /// counted on after the turn ended, though the add-on had sent every end).
    private nonisolated static func described(_ activity: Activity<HQLiveAttributes>) -> String {
        let state = activity.content.state
        let minutes = Int(Date().timeIntervalSince(state.startedAt) / 60)
        let tries = PushAlertDiagnostics.counts().filter { $0.key.hasPrefix("liveEnd.") && !$0.key.hasSuffix("LastAt") }
            .sorted { $0.key < $1.key }.map { "\($0.key.dropFirst(8)) \(Int($0.value))" }
        return "\(activity.activityState), \(state.phase.rawValue), \(minutes) min, " + (state.seal == nil ? "last change by the app" : "last change pushed")
            + (tries.isEmpty ? "" : " (extension: " + tries.joined(separator: ", ") + ")")
    }
}
#endif

/// [live-steps] What the gateway's add-on needs to push a turn's steps to its card: the activity's push token, the turn
/// (bot and its Bot Chat's stored id), when it began (the card's clock, echoed back in every push) and what the card
/// already says.
struct LiveStepsHandOver: Equatable, Sendable {
    var activity: String
    var token: String
    var profile: String
    var session: String?
    var startedAt: Date
    var trail: LiveStepTrail
}

/// [live-steps] PushRegistrar in the app (Notifications/PushRegistrar.swift); a recorder in the tests.
@MainActor protocol LiveStepsRelay: AnyObject {
    func handOverSteps(_ start: LiveStepsHandOver) async
    func withdrawSteps(_ activity: String) async
}

extension HQPalette {
    /// [live] The theme's tint for a Lock Screen card (always drawn dark), red green blue 0…1: the widget extension has
    /// no theme, and its `.accentColor` was system blue.
    static var cardAccent: [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Double(min(max($0, 0), 1)) }
    }
}
