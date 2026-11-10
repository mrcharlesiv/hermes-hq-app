// [presence] A bot's browser and screen use, outside the viewer (docs/spec/3x-presence.md §3.3). One centre per
// signed-in account, owned by AppModel. It hears the account's gateway events (`tool.start`, `message.complete`) and the
// browser plugin's list, and feeds two things: each bot's `BotPresence` on the Bots rows ("Using its computer",
// "Browsing example.com") and the "<bot> is using its browser / screen" notice with Watch.
//
// Nothing here is stored and nothing is sent: the rules are HermesKit/Presence/PresenceRules.swift.

import UIKit

/// Set by AppModel once; called by the Bots list as it comes on screen and leaves it.
@MainActor enum PresenceHooks {
    /// (the list's controller, on screen). The controller is named so a list that went away with its gateway cannot
    /// switch off the list that replaced it.
    static var botsListShown: ((UIViewController, Bool) -> Void)?
    /// Sessions or More is the tab on show (the tabs say so on every change; UX study #135).
    static var askTabShown: ((Bool) -> Void)?
}

@MainActor final class PresenceCenter {
    struct Context {
        /// §3.1: runtime id → the bot whose chat it is (never the event's own `profile`), nil when nobody owns it.
        var owner: (String) -> String?
        var bots: () -> [Bot]
        /// The bot's switch (`BotStore.screenNoticeOn`), read each time: a flip counts for the next tool call.
        var noticeOn: (String) -> Bool
        /// The bot of the chat on screen.
        var visibleChatProfile: () -> String?
        var face: (String) -> BotFaces.Face?
        var window: () -> UIWindow?
        /// The notice's Watch for a browser (§8.4). The second value runs when Watch could not open it (an alert stayed
        /// on top for the whole wait): the centre puts the notice back.
        var openBrowser: (BrowserScope, @escaping () -> Void) -> Void
        /// The notice's Watch for a screen (the screen stream's viewer, through `BotComputerHooks.openScreen`).
        var openScreen: (Bot, @escaping () -> Void) -> Void
        var publish: ([String: BotPresence]) -> Void
        /// The stored ids of a bot's own Bot Chat (`BotStore.ownChatIds`); nil while the roster doesn't know the bot.
        var ownChats: (String) -> Set<String>? = { _ in nil }
        /// The app is in the background (it runs on for a moment after leaving): nothing is shown to nobody.
        var inBackground: () -> Bool = { UIApplication.shared.applicationState == .background }
    }

    /// At most one roster rebuild per this long from presence changes; a trailing publish always goes out.
    static let publishGap: Duration = .milliseconds(250)

    private weak var browser: BrowserService?
    private let context: Context
    private let clock = ContinuousClock()
    private var computer = ComputerActivity()
    private var gate = NoticeGate()
    private var browserLines: [String: String] = [:]
    /// The ask each browser carried when the list was last read (by browser id): a new one raises the notice once.
    private var asksSeen: [String: String] = [:]
    private var subscription: BrowserSubscription?
    /// Held while Sessions or More shows (UX study #135), so an ask is heard there too.
    private var askSubscription: BrowserSubscription?
    private var expiry: Task<Void, Never>?
    private var coalesce: Task<Void, Never>?
    private var lastPublish: ContinuousClock.Instant?
    private var listShown = false
    private var isShutDown = false
    /// What a tool start led to, newest last (tests and the diagnostic log; the reason only, never a name or an argument).
    private(set) var debugOutcomes: [NoticeGate.Outcome] = []
    private(set) var publishes = 0
    /// How many times a Watch that could not open asked for its notice back (tests and the log).
    private(set) var watchesOfferedAgain = 0

    init(browser: BrowserService?, context: Context) {
        self.browser = browser
        self.context = context
        // DECISION D40 (UX study #135): an ask in the plugin's list is heard while anything on screen has the list open
        // (the Bots list, a chat's card, a viewer), whoever opened it.
        browser?.activity.onRowsChanged = { [weak self] in self?.asksChanged() }
    }

    // MARK: Events

    func handle(_ event: GatewayEvent) {
        guard !isShutDown else { return }
        switch event.type {
        case "tool.start": toolStarted(event)
        case "message.complete":
            // The reply finished: its bot is no longer "Using its computer" (an errored or stopped turn waits out its 90 s,
            // as on the web).
            if let profile = context.owner(event.sessionId), computer.replyFinished(profile) {
                armExpiry()
                schedulePublish(trailing: event.replayed)
            }
        default: break
        }
    }

    private func toolStarted(_ event: GatewayEvent) {
        let name = event.payload["name"]?.string
        guard ScreenTools.isScreenTool(name) else { return }
        let profile = context.owner(event.sessionId)
        let now = clock.now
        // The row: replayed starts count too (the web's computer-activity has no replay check). A replayed start waits
        // out the coalescing gap before it shows: a reconnect replays a finished turn's start and its end in one burst,
        // and publishing the start at once made the row flash "Using its computer" for a turn that was already over.
        if let profile {
            computer.toolStarted(profile, at: now)
            armExpiry()
            schedulePublish(trailing: event.replayed)
        }
        // The notice. Not while the app is in the background: it would be found, stale, on the return (the notice leaves
        // when the app does). Checked before the gate, so no cooldown is stamped for a notice nobody saw.
        if context.inBackground() {
            record(.none("in the background"), now: now)
            return
        }
        let outcome = gate.decide(.init(
            replayed: event.replayed, toolName: name, profile: profile,
            noticeOn: profile.map(context.noticeOn) ?? false,
            visibleChatProfile: context.visibleChatProfile(),
            screenViewerOpen: BotComputerHooks.screenIsOpen?() ?? false,
            watchingThisBrowser: profile.map(BrowserViewerController.isWatching(profile:)) ?? false,
            canWatchScreen: BotComputerHooks.openScreen != nil), now: now)
        record(outcome, now: now)
        switch outcome {
        case .none: break
        case .browser: notify(profile, .browser)
        case .screen: notify(profile, .screen)
        }
    }

    private func record(_ outcome: NoticeGate.Outcome, now: ContinuousClock.Instant) {
        debugOutcomes.append(outcome)
        if debugOutcomes.count > 64 { debugOutcomes.removeFirst(debugOutcomes.count - 64) }
        guard case .none(let reason) = outcome else { return }
        // A burst of tool calls says "cooldown" once, not five hundred times: each reason at most once in 10 s.
        if let said = reasonSaid[reason], now - said < .seconds(10) { return }
        reasonSaid[reason] = now
        AppLog.note("presence", "no notice: \(reason)")
    }

    /// When each "no notice" reason was last written to the log (a handful of fixed words, never a name).
    private var reasonSaid: [String: ContinuousClock.Instant] = [:]

    private func notify(_ profile: String?, _ kind: PresenceNotice.Kind) {
        guard let profile, let bot = context.bots().first(where: { $0.id == profile }), context.window() != nil else {
            AppLog.note("presence", "no notice: nowhere to show it")
            return
        }
        AppLog.note("presence", "notice: \(kind == .screen ? "screen" : kind == .browser ? "browser" : "browser ask")")
        show(PresenceNotice.Alert(profile: profile, name: bot.name, kind: kind, face: context.face(profile)))
    }

    private func show(_ alert: PresenceNotice.Alert) {
        guard !isShutDown, let window = context.window() else { return }
        PresenceNotice.shared.show(alert, in: window) { [weak self] alert in self?.watch(alert) }
    }

    /// Watch was tapped. When it could not open (an alert stayed on top for the whole wait) the notice comes back, so
    /// Watch is still on offer: the tap took the notice away and the bot's 30 s is already running.
    private func watch(_ alert: PresenceNotice.Alert) {
        guard !isShutDown else { return }
        let again: () -> Void = { [weak self] in self?.offerAgain(alert) }
        switch alert.kind {
        case .browser, .browserAsk: context.openBrowser(BrowserScope(profile: alert.profile, title: alert.name), again)
        case .screen:
            // The bot as the roster has it now (it may have been renamed or removed since).
            if let bot = context.bots().first(where: { $0.id == alert.profile }) { context.openScreen(bot, again) }
        }
    }

    private func offerAgain(_ alert: PresenceNotice.Alert) {
        watchesOfferedAgain += 1
        // Nothing left to offer: its viewer came up some other way, the bot went, or the app did.
        guard !isShutDown, !context.inBackground(), context.bots().contains(where: { $0.id == alert.profile }) else { return }
        if alert.kind != .screen, BrowserViewerController.isWatching(profile: alert.profile) { return }
        AppLog.note("presence", "notice: Watch offered again")
        show(alert)
    }

    // MARK: A browser that needs the person (DECISION D40)

    /// The bot's browser asked for the person (sign-in step, code, CAPTCHA): "<bot> needs you in its browser" with
    /// Watch, once per ask. Gated as the "is using" notice is (D5): the bot's own switch only, never Mute; not in the
    /// background, and not when that bot's chat or viewer is already on screen (its card says so there).
    private func asksChanged() {
        guard !isShutDown, let browser else { return }
        var fresh: [BrowserRow] = []
        for row in browser.activity.rows {
            let ask = row.control == .bot ? row.ask : nil
            if let ask, asksSeen[row.id] != ask { fresh.append(row) }
            asksSeen[row.id] = ask
        }
        guard let row = fresh.max(by: { $0.agentAt < $1.agentAt }) else { return }
        let profile = row.profile
        let onScreen = context.visibleChatProfile() == profile || BrowserViewerController.isWatching(profile: profile)
        let reason: String? = context.inBackground() ? "in the background" : !context.noticeOn(profile) ? "switched off"
            : onScreen ? "already on screen" : nil
        if let reason {
            AppLog.note("presence", "no ask notice: \(reason)")
            return
        }
        notify(profile, .browserAsk)
    }

    // MARK: The 90 s fall-back

    /// One task that sleeps until the earliest window ends (+50 ms, as on the web), republishes, and re-arms while any
    /// bot is still active.
    private func armExpiry() {
        expiry?.cancel()
        expiry = nil
        guard let next = computer.nextExpiry() else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(until: next + .milliseconds(50), clock: .continuous)
            guard !Task.isCancelled, let self, !self.isShutDown else { return }
            self.expiry = nil
            _ = self.computer.active(at: self.clock.now)      // drops the ones whose window ended
            self.schedulePublish()
            self.armExpiry()
        }
    }

    // MARK: The browser plugin's list (the Bots rows' "Browsing …" line)

    /// The Bots list is on screen: its rows read the plugin's list. Off: the subscription goes (the channel lingers 3 s,
    /// so a chat opened from the list keeps the one socket); the lines are kept and worked out again when it is back.
    func setBotsListShown(_ shown: Bool) {
        guard !isShutDown, shown != listShown else { return }
        listShown = shown
        if shown {
            guard let browser else { return }
            subscription = browser.activity.subscribe { [weak self] in self?.listChanged() }
            listChanged()
        } else {
            subscription?.cancel()
            subscription = nil
        }
    }

    /// UX study #135: Sessions or More is the tab on show. Nothing there opens the plugin's list, so asks went unheard;
    /// the centre listens itself while one of them shows. It is the same shared socket (list only, no images), opened
    /// once per stay in the foreground: the channel closes it in the background and dials again on the return.
    func setAsksHeard(_ on: Bool) {
        guard !isShutDown, on != (askSubscription != nil) else { return }
        if on {
            guard let browser else { return }
            askSubscription = browser.activity.subscribe {}   // asks arrive through `onRowsChanged`
        } else {
            askSubscription?.cancel()
            askSubscription = nil
        }
    }

    /// The roster changed (a bot came, went or was renamed): the lines follow.
    func botsChanged() {
        guard !isShutDown, listShown else { return }
        listChanged()
    }

    private func listChanged() {
        guard let browser else { return }
        let rows = browser.activity.rows
        var lines: [String: String] = [:]
        if !rows.isEmpty {
            for bot in context.bots() {
                let row = BrowserCard.botRow(rows, profile: bot.id, ownChats: context.ownChats(bot.id))
                if let line = BrowserCard.statusLine(row) { lines[bot.id] = line }
            }
        }
        guard lines != browserLines else { return }
        browserLines = lines
        schedulePublish()
    }

    // MARK: Publishing (coalesced)

    /// `trailing`: never at once, always after the gap (a replayed event: what follows it in the same burst may undo it).
    private func schedulePublish(trailing: Bool = false) {
        guard coalesce == nil else { return }          // a trailing publish is already on its way
        let now = clock.now
        var wait: Duration?
        if let last = lastPublish, now - last < Self.publishGap { wait = Self.publishGap - (now - last) }
        if trailing { wait = Self.publishGap }
        guard let wait else { publishNow(); return }
        coalesce = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.coalesce = nil
            self.publishNow()
        }
    }

    private func publishNow() {
        guard !isShutDown else { return }
        lastPublish = clock.now
        var map: [String: BotPresence] = [:]
        for (profile, line) in browserLines { map[profile, default: BotPresence()].browserLine = line }
        for profile in computer.active(at: clock.now) { map[profile, default: BotPresence()].usingComputer = true }
        publishes += 1
        context.publish(map)
    }

    // MARK: Leaving

    /// Sign-out or another gateway: timers, the subscription, the notice and every map go.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        expiry?.cancel(); expiry = nil
        coalesce?.cancel(); coalesce = nil
        subscription?.cancel(); subscription = nil
        askSubscription?.cancel(); askSubscription = nil
        computer.reset()
        gate.reset()
        browserLines = [:]
        asksSeen = [:]
        browser?.activity.onRowsChanged = nil
        PresenceNotice.shared.dismiss(up: true)
        context.publish([:])
    }

    #if DEBUG
    /// Tests: the notice's Watch, as a tap on it runs.
    func debugWatch(_ alert: PresenceNotice.Alert) { watch(alert) }
    var debugSubscribed: Bool { subscription != nil }
    var debugAsksHeard: Bool { askSubscription != nil }
    var debugExpiryArmed: Bool { expiry != nil }
    #endif
}
