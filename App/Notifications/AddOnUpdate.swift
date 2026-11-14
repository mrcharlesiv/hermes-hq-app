// [addon-progress] Owner 2026-11-04, on a test gateway: Update did nothing they could see for 30 seconds or more, then
// the main bot's chat opened with a restart request; after the restart the row still said an update was there, and a
// second tap gave the tap's buzz and nothing else. The app read every bot's add-ons and installed bot by bot with
// nothing on screen; the newest add-on out (0.9.31) was older than the build asked for (0.9.32), so no restart could
// finish the job; and a tap while a check ran, or when Hermes didn't answer, ended without a word.
// Now an update shows one sheet from the tap on. Its steps tick off as they finish (Check Hermes; Install, naming the
// bot and the count; Restart Hermes, naming the bot that does it; Check it's on), and it ends in words: on, up to date,
// not out yet, couldn't reach Hermes, or Hermes hasn't restarted yet. It may be closed at any point: the update goes on,
// Settings' row says "Updating…", and a tap there (or on any Update button) brings the sheet back.
// [browser-update] Owner 2026-11-05: the browser add-on (hermes-hq-browser) updates "in the exact same like user
// experience", where "they can watch it actually update". The same sheet takes it alone or with the notification
// add-on (one install pass, one restart): its steps and endings name the add-on, or both, and "Check it's on" reads the
// browser add-on's /health too (BrowserAddOn.isOn).
// [manual-restart] Tester 2026-11-10: their Hermes needs sudo to restart, so being taken to the main bot's chat for it
// was the wrong step. Under Update there is now a switch, kept per gateway (also in Settings › Notifications): the bot is
// asked in its chat, as before, or "I'll Restart Hermes Myself". Then no chat opens: the sheet ends on "Restart Hermes to
// Finish", and the app watches (for a day, not 15 minutes) and finishes once Hermes is back. "Ask <bot> Instead" hands
// that one restart to the bot after all.
// [plugin-updates] Owner 2026-11-11: a plugin with an update "shows just like an update for the HQ plugin". The same
// sheet runs it (PluginUpdateFlow, App/Capabilities/PluginUpdates.swift): the same steps, the same restart choice, and
// words that name the plugin (`pluginRun`, `plugins`).

import SwiftUI
import UIKit

@MainActor @Observable final class AddOnUpdate {
    static let shared = AddOnUpdate()

    enum StepID: String, CaseIterable, Sendable { case check, install, restart, verify }
    /// `failed`: the step under way when the update failed (Mac polish #48: it went back to an empty circle, which read
    /// as not started; Update Hermes marks it with a red ✕, and so does this sheet now).
    enum StepState: Equatable, Sendable { case waiting, active, done, skipped, failed }

    struct Step: Identifiable, Equatable {
        let id: StepID
        var title: String
        var state: StepState = .waiting
        /// What's happening in it right now ("Finance · 4 of 11"), or before it starts, what it will do.
        var detail: String?
        var started: Date?
        var finished: Date?
    }

    nonisolated enum End: Equatable, Sendable {
        /// The add-on is on (its version, when known).
        case on(version: String?)
        case upToDate
        /// Hermes has the newest add-on out (`have`), still older than this build asks for (`want`). `browser`: the
        /// browser add-on's ([browser-update]).
        case notOut(have: String, want: String, browser: Bool = false)
        /// Hermes didn't answer the check.
        case unreachable
        /// The restart wasn't seen in time; the app goes on watching.
        case slow
        /// [manual-restart] Installed; the owner restarts Hermes themselves, and the app goes on watching.
        case yours
        case failed(title: String, reason: String)
        /// [plugin-ask-bot] Done as far as the app can: what's left is the main bot's to do from its chat, on the
        /// owner's tap (plugins whose update adds Python packages).
        case more(title: String, reason: String)
    }

    nonisolated enum Phase: Equatable, Sendable { case idle, checking, asking, working, ended(End) }

    /// [browser-update] Which add-ons this run is about: the notification add-on (as before), the browser add-on's
    /// update alone, or both.
    nonisolated enum AddOns: Equatable, Sendable { case push, browser, both }

    private(set) var phase: Phase = .idle
    private(set) var steps: [Step] = []
    /// A first setup (no add-on yet) rather than an update.
    private(set) var setUp = false
    /// What isn't working without it (AddOnReminder's words).
    private(set) var why = ""
    /// The main bot, which restarts Hermes from its chat.
    private(set) var botName = ""
    /// More than one add-on goes in (a first setup brings Watch Browser's).
    private(set) var both = false
    /// [browser-update] The browser add-on's update alone, or with the notification add-on (then `both` too).
    private(set) var addOns: AddOns = .push
    /// The add-on's version once installed.
    private(set) var version: String?
    /// [browser-update] The browser add-on's version once installed.
    private(set) var browserVersion: String?
    /// The restart is being watched for (also after the sheet said it's slow).
    private(set) var watching = false
    /// [addon-whats-new] What the update brings, one card per add-on (read while the sheet asks; empty until then).
    private(set) var changes: [Changing] = []

    /// [addon-whats-new] One add-on in the update: its name, the version Hermes has and the one it gets, and what the
    /// versions between them do.
    struct Changing: Identifiable, Equatable {
        var id: String { plugin }
        let plugin: String
        let title: String
        var from: String?
        var to: String?
        var lines: [AddOnChanges.Change] = []
        /// GitHub's answer is still on its way.
        var loading = true
        /// [plugin-updates] A quiet line under the name ("For Hermes and Finance").
        var note: String? = nil
    }

    /// [plugin-updates] This run updates other plugins (PluginUpdateFlow), not the app's add-ons.
    private(set) var pluginRun = false
    /// The plugins it updates (empty until the check has found them).
    private(set) var plugins: [String] = []

    /// [manual-restart] The owner restarts Hermes themselves after an add-on goes in (this gateway's choice).
    private(set) var byHand = false
    /// The choice is offered (not on Hermes Cloud, whose computer the owner can't get to).
    private(set) var canChooseRestart = false

    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private weak var sheet: UIViewController?
    @ObservationIgnored private weak var model: AppModel?

    /// An update (or the check before it) is under way: a tap brings the sheet back instead of starting another.
    var busy: Bool {
        switch phase {
        case .checking, .asking, .working: true
        case .ended: watching
        case .idle: false
        }
    }

    /// The sheet over everything, if it's up.
    var shownSheet: UIViewController? { sheet?.presentingViewController == nil ? nil : sheet }

    // MARK: Driving it (PushSetupOffer)

    /// A tap: the sheet opens on "Checking Hermes…".
    func begin(model: AppModel) {
        settleAnswer(false)
        self.model = model
        canChooseRestart = !CloudGatewayFlow.isCloud(model.account?.baseURL)
        byHand = canChooseRestart && Self.restartsByHand(account: model.account?.id)
        phase = .checking
        version = nil
        browserVersion = nil
        both = false
        addOns = .push
        pluginRun = false
        plugins = []
        steps = [Step(id: .check, title: Self.checkTitle, state: .active, started: Date())]
        changes = []
    }

    /// [plugin-updates] The same opening for a plugin update.
    func beginPlugins(model: AppModel) {
        begin(model: model)
        pluginRun = true
        setUp = false
    }

    /// [plugin-updates] What the check found: the plugins with an update, a card each, and the steps to come.
    func foundPlugins(_ names: [String], why: String, bot: String, installNote: String?, cards: [Changing]) {
        plugins = names
        self.why = why
        botName = bot
        let started = steps.first { $0.id == .check }?.started ?? Date()
        steps = [
            Step(id: .check, title: Self.checkTitle, state: .done, started: started, finished: Date()),
            Step(id: .install, title: names.count > 1 ? "Install the updates" : "Install the update", detail: installNote),
            Step(id: .restart, title: Self.restartTitle, detail: byHand ? Self.restartPlanMine : Self.restartPlan(bot)),
            Step(id: .verify, title: Self.verifyTitle(both: names.count > 1)),
        ]
        changes = cards
    }

    /// What the check found: the steps to come, and the words for the question (`asking`) or the work.
    /// `installNote`: which bots get a copy (the steps say what's about to happen before the tap).
    /// [browser-update] `browserOnly`: only the browser add-on's update (`both` is false then).
    func found(setUp: Bool, why: String, bot: String, both: Bool, browserOnly: Bool = false, installNote: String? = nil) {
        self.setUp = setUp
        self.why = why
        botName = bot
        self.both = both
        addOns = browserOnly ? .browser : both ? .both : .push
        let started = steps.first { $0.id == .check }?.started ?? Date()
        steps = [
            Step(id: .check, title: Self.checkTitle, state: .done, started: started, finished: Date()),
            Step(id: .install, title: Self.installTitle(setUp: setUp, both: both, addOns: addOns), detail: installNote),
            Step(id: .restart, title: Self.restartTitle, detail: byHand ? Self.restartPlanMine : Self.restartPlan(bot)),
            Step(id: .verify, title: Self.verifyTitle(both: both)),
        ]
    }

    // MARK: Who restarts Hermes ([manual-restart])

    /// Account → true where the owner restarts Hermes themselves.
    nonisolated static let byHandKey = "push.addOnRestart.byHand"

    nonisolated static func restartsByHand(account: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let account else { return false }
        return defaults.dictionary(forKey: byHandKey)?[account] as? Bool == true
    }

    nonisolated static func setRestartsByHand(_ on: Bool, account: String?, defaults: UserDefaults = .standard) {
        guard let account else { return }
        var all = defaults.dictionary(forKey: byHandKey) ?? [:]
        all[account] = on ? true : nil
        defaults.set(all.isEmpty ? nil : all, forKey: byHandKey)
    }

    /// The choice under Update while the sheet asks: kept for this gateway, and the Restart step says what will happen.
    func chooseRestart(byHand on: Bool) {
        guard canChooseRestart, on != byHand else { return }
        byHand = on
        Self.setRestartsByHand(on, account: model?.account?.id)
        Haptics.play(.selection)
        AppLog.note("push", "update sheet: restart \(on ? "left to the owner" : "asked of the bot")")
        if let index = steps.firstIndex(where: { $0.id == .restart }), steps[index].state == .waiting {
            steps[index].detail = on ? Self.restartPlanMine : Self.restartPlan(botName)
        }
    }

    /// The choice shows under Update: while the sheet asks, where there is one to make.
    var offersRestartChoice: Bool { phase == .asking && canChooseRestart }

    /// "Ask <bot> Instead", on "Restart Hermes to Finish": this one restart goes to the bot's chat after all.
    func askBotInstead() {
        guard phase == .ended(.yours) else { return }
        if pluginRun { PluginUpdateFlow.shared.askBotInstead(); return }   // [plugin-updates]
        PushSetupOffer.shared.askBotInstead()
    }

    /// [addon-whats-new] Reads what the update brings while the sheet asks: the versions Hermes has (the main bot's
    /// add-on list) and each add-on's newer releases from GitHub. The sheet shows the names at once and fills in.
    func loadChanges(store: CapabilitiesStore?) {
        var items: [Changing] = []
        if addOns != .browser { items.append(Changing(plugin: PushPolicy.pluginName, title: Self.pushName)) }
        if addOns != .push { items.append(Changing(plugin: PushSetupOffer.browserPlugin, title: Self.browserName)) }
        changes = items
        Task { @MainActor [weak self] in
            var installed: [String: String] = [:]
            if let store, let list = try? await store.plugins("default") {
                for plugin in list where items.contains(where: { $0.plugin == plugin.name }) { installed[plugin.name] = plugin.version }
            }
            for item in items {
                var filled = item
                filled.from = installed[item.plugin].flatMap { PushPolicy.versionAtLeast($0, "0") ? $0 : nil }
                if let url = AddOnChanges.url(plugin: item.plugin) {
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                        filled.lines = AddOnChanges.parse(data, plugin: item.plugin, after: filled.from)
                    } else {
                        AppLog.note("push", "update sheet: what's new for \(item.plugin) not read")
                    }
                }
                filled.to = AddOnChanges.newest(filled.lines)
                filled.loading = false
                guard let self, let index = self.changes.firstIndex(where: { $0.plugin == item.plugin }) else { return }
                self.changes[index] = filled
            }
        }
    }

    /// [browser-update] Nothing to do, said for the add-ons Hermes has: both when the browser add-on is there too.
    func checked(browser: Bool) { addOns = browser ? .both : .push }

    /// [browser-update] One add-on's part of an update of both didn't go in: the steps and the ending follow the other.
    func only(_ kind: AddOns) {
        guard kind != .both, addOns == .both else { return }
        addOns = kind
        both = false
        if let index = steps.firstIndex(where: { $0.id == .install }) { steps[index].title = Self.installTitle(setUp: setUp, both: false, addOns: kind) }
        if let index = steps.firstIndex(where: { $0.id == .verify }) { steps[index].title = Self.verifyTitle }
    }

    /// The sheet asks before anything changes. False: Not Now, or the sheet closed. `presenter`: put the sheet up too
    /// (the launch offer, which has no sheet yet).
    func ask(presenting presenter: UIViewController? = nil) async -> Bool {
        settleAnswer(false)
        phase = .asking
        if let presenter { show(from: presenter) }
        return await withCheckedContinuation { answer = $0 }
    }

    func work() { if phase != .working { phase = .working } }

    func step(_ id: StepID, _ state: StepState, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let was = steps[index].state
        steps[index].state = state
        steps[index].detail = state == .done ? nil : detail
        if state == .active, was != .active { steps[index].started = Date() }
        if state == .done || state == .skipped { steps[index].finished = Date() }
        if state == .done, was != .done { Haptics.play(.light) }
    }

    func detail(_ id: StepID, _ words: String?) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].detail != words else { return }
        steps[index].detail = words
    }

    /// Steps a later sign finished (the restart, seen as the add-on answering current).
    func complete(_ ids: [StepID]) {
        for id in ids where steps.first(where: { $0.id == id })?.state != .done { step(id, .done) }
    }

    func installed(version: String?) { if let version { self.version = version } }
    func installed(browser version: String?) { if let version { browserVersion = version } }

    /// A sign-out, a gateway switch, or a check that stopped with nothing to show: no update stays, the sheet closes.
    func reset() {
        settleAnswer(false)
        watching = false
        phase = .idle
        steps = []
        pluginRun = false
        plugins = []
        close()
    }

    func watch(_ on: Bool) { watching = on }

    func end(_ end: End) {
        settleAnswer(false)
        // Whatever was under way when it ended stops spinning.
        for index in steps.indices where steps[index].state == .active {
            if case .on = end { steps[index].state = .done; steps[index].finished = Date() }
            else if end == .slow || end == .yours, steps[index].id == .restart { continue }
            else if case .failed = end { steps[index].state = .failed; steps[index].finished = Date() }
            else { steps[index].state = .waiting }
        }
        // What a step was going to do no longer applies once it's over.
        for index in steps.indices where steps[index].state == .waiting { steps[index].detail = nil }
        phase = .ended(end)
        switch end {
        case .on, .upToDate: Haptics.play(.success)
        case .notOut, .slow, .yours, .more: break
        case .unreachable, .failed: Haptics.play(.warning)
        }
        AppLog.note("push", "update sheet: \(Self.logWord(end))")
    }

    /// The sheet's Update / Set Up.
    func confirm() { settleAnswer(true) }

    private func settleAnswer(_ value: Bool) {
        guard let pending = answer else { return }
        answer = nil
        pending.resume(returning: value)
    }

    // MARK: The sheet

    /// Presents the sheet over whatever is on top (or brings it back). `presenter`: where the tap was.
    func show(from presenter: UIViewController?) {
        if let shownSheet, shownSheet.view.window != nil { return }
        guard let host = FailureAlert.topmost(presenter ?? MainTabController.current) else { return }
        let controller = AddOnUpdateController(update: self)
        SheetStyle.macTall(controller, from: host)   // [mac] the other sheets' size, not the system's small one
        sheet = controller
        host.present(controller, animated: true)
    }

    /// The sheet closed (Hide, Done, Not Now or a swipe down). An open question is Not Now; the work goes on.
    func sheetClosed() {
        settleAnswer(false)
        if phase == .asking { phase = .idle }
        if case .ended(let end) = phase, end != .slow, end != .yours { phase = .idle }
    }

    func close() { sheet?.dismiss(animated: true) }

    /// Try Again: the same check from the start, in this sheet.
    func retry() {
        guard let model else { return }
        let host = sheet?.presentingViewController
        if pluginRun { PluginUpdateFlow.shared.retry(model: model, from: host); return }   // [plugin-updates]
        Task { @MainActor in _ = await PushSetupOffer.shared.check(model: model, fromSettings: true, from: host) }
    }

    /// The main bot's chat, where it says how the restart went.
    func openBotChat() {
        let open = {
            guard let root = MainTabController.current else { return }
            root.select(.bots)
            root.botsViewController.navigationController?.popToRootViewController(animated: false)
            root.botsViewController.open("default")
        }
        if let sheet, sheet.presentingViewController != nil { sheet.dismiss(animated: true) { open() } } else { open() }
    }

    // MARK: Words

    nonisolated static let pushName = "Hermes HQ Add-on"
    nonisolated static let browserName = "Browser Add-on"
    /// "0.9.33 → 0.9.40", "New · 0.9.40" (not there yet), "0.9.33 → newest" (GitHub didn't answer).
    nonisolated static func versions(from: String?, to: String?, setUp: Bool) -> String? {
        switch (from, to) {
        // [plugin-update-run] A newer build under the same version number ("2.0.1 → 2.0.1" said nothing).
        case let (from?, to?): return from == to ? "\(from) · newer build" : "\(from) → \(to)"
        case let (nil, to?): return setUp ? "New · \(to)" : "To \(to)"
        case let (from?, nil): return "\(from) → newest"
        case (nil, nil): return nil
        }
    }

    nonisolated static let checkTitle = "Check Hermes"
    nonisolated static func installTitle(setUp: Bool, both: Bool, addOns: AddOns = .push) -> String {
        if addOns == .browser { return "Install the browser update" }   // [browser-update]
        if both { return setUp ? "Install the add-ons" : "Install both updates" }
        return setUp ? "Install the add-on" : "Install the update"
    }
    nonisolated static let restartTitle = "Restart Hermes"
    nonisolated static let verifyTitle = "Check it’s on"
    /// [browser-update] Two add-ons are checked at the end.
    nonisolated static func verifyTitle(both: Bool) -> String { both ? "Check they’re on" : verifyTitle }

    nonisolated static func installing(_ name: String, _ index: Int, of total: Int) -> String {
        total > 1 ? "\(name) · \(index) of \(total)" : name
    }
    /// [browser-update] The install step's line while the browser add-on goes in: the main bot's copy (the others get
    /// theirs from it when Hermes starts), counted after the notification add-on's bots.
    nonisolated static func browserCopy(_ bot: String) -> String { "\(bot)’s browser add-on" }
    /// [browser-update] Reading the browser add-on's /health in the last step.
    nonisolated static let browserCheck = "Checking the browser add-on"
    nonisolated static let loading = "Checking it loaded"
    nonisolated static func botInstalls(_ bot: String) -> String { "\(bot) installs it from its chat" }
    nonisolated static func botRestarts(_ bot: String) -> String { "Asked \(bot) in its chat. Usually under a minute." }
    nonisolated static let notNeeded = "Not needed"
    /// [addon-progress] Before the tap: the restart opens the bot's chat, which surprised the owner when it just happened.
    nonisolated static func restartPlan(_ bot: String) -> String { "Opens \(bot)’s chat to do it. Replies pause a few seconds." }
    /// [manual-restart] The same line when the owner does it, and the step's line while the app waits for them.
    nonisolated static let restartPlanMine = "You do it on Hermes’s computer. The app waits for it."
    nonisolated static let youRestart = "Waiting for you to restart it on its computer."
    nonisolated static func askInstead(_ bot: String) -> String { "Ask \(bot) Instead" }
    /// The switch under Update, and in Settings › Notifications.
    nonisolated static let byHandToggle = "I’ll Restart Hermes Myself"
    /// Settings' line under the switch.
    nonisolated static func byHandNote(_ bot: String, on: Bool) -> String {
        on ? "After an add-on update, you restart it on its computer." : "After an add-on update, \(bot) restarts it from its chat."
    }
    /// The watch ran out with no restart seen.
    nonisolated static let notRestartedReason = "Hermes hasn’t restarted with the add-on. Restart it on its computer, then update again from Settings › Notifications."
    /// [browser-update] `browser`: the browser add-on's update goes in too (for every bot: it adds itself to the others).
    nonisolated static func installPlan(bots: [String], all: Int, browser: Bool = false) -> String? {
        if !bots.isEmpty { return "For " + AddOnReminder.names(bots) + (browser ? ", and the browser add-on for all" : "") }
        return all > 1 ? "For all \(all) bots" : nil
    }
    nonisolated static let takesAboutAMinute = "Takes about a minute."

    /// [addon-progress] The question's one line: what the add-on is, and why this one. The owner found the old alert
    /// "too much to read", and not clear on what the update was for or why to tap it.
    nonisolated static func why(_ need: AddOnReminder.Need, both: Bool) -> String {
        let app = AppIdentity.current.displayName
        switch need {
        case .missing where both:
            return "\(app) works through two small add-ons in Hermes: one alerts you while the app is closed, one lets you watch a bot’s browser."
        case .missing:
            return "\(app) works through a small add-on in Hermes. It alerts you while the app is closed and lets bots ask you things on a card."
        case .outdated:
            return "\(app) works through a small add-on in Hermes. This version of the app needs a newer one, or some alerts and features won’t work."
        case .bots(let names):
            let one = names.count == 1
            return "\(AddOnReminder.names(names)) \(one ? "doesn’t" : "don’t") have the add-on yet, so \(one ? "its" : "their") alerts and questions can’t reach you."
        }
    }
    /// [browser-update] The same line when the browser add-on needs its update: alone, or after the notification
    /// add-on's need (`need` nil: only the browser's).
    nonisolated static func why(_ need: AddOnReminder.Need?, browser: BrowserAddOn.Need) -> String {
        let app = AppIdentity.current.displayName
        guard let need else {
            return browser == .off
                ? "The browser add-on in Hermes switched itself off after Hermes updated, so you can’t watch a bot’s browser. Add-on \(BrowserAddOn.wantedVersion) turns it back on."
                : "\(app) shows a bot’s browser through a small add-on in Hermes. This version of the app needs a newer one, or watching may not work."
        }
        switch need {
        case .missing:
            return "\(app) needs a small add-on in Hermes to alert you while the app is closed, and its browser add-on needs an update."
        case .outdated:
            return "\(app) works through two small add-ons in Hermes, and both need updating: one alerts you while the app is closed, one lets you watch a bot’s browser."
        case .bots(let names):
            let one = names.count == 1
            return "\(AddOnReminder.names(names)) \(one ? "doesn’t" : "don’t") have the add-on yet, so \(one ? "its" : "their") alerts can’t reach you, and the browser add-on needs an update."
        }
    }
    /// [browser-update] Hermes restarted, but the browser add-on isn't on at the version this build needs.
    nonisolated static let browserStillOff = "Browser Add-on Is Still Off"
    nonisolated static func browserStillOffReason(_ health: JSONValue?, bot: String) -> String {
        let version = health.map(BrowserAddOn.version) ?? ""
        let got: String
        if let health, let words = BrowserHealth.driftWords(health) { got = "Hermes restarted, but the browser add-on says: \(words)." }
        else if !version.isEmpty, !BrowserAddOn.restarted(health ?? .null) { got = "Hermes restarted, but its browser add-on is still \(version)." }
        else { got = "Hermes restarted, but its browser add-on didn’t come up." }
        return "\(got) Try again, or ask \(bot) in its chat."
    }

    /// After the restart some bots' own copies still aren't there.
    nonisolated static func stillNeed(_ names: [String]) -> String {
        "\(AddOnReminder.names(names)) Still \(names.count == 1 ? "Needs" : "Need") It"
    }
    nonisolated static func stillNeedReason(count: Int, bot: String) -> String {
        "Hermes restarted with the add-on, but \(count == 1 ? "that bot’s own copy" : "those bots’ own copies") didn’t go in. Try again, or ask \(bot) in its chat."
    }
    nonisolated static let eachBot = "Checking each bot’s copy"

    /// [addon-progress] Settings' row while an update runs.
    nonisolated static let rowTitle = "Updating Add-on…"
    /// [browser-update] The row names the browser add-on, or both.
    var rowLabel: String {
        if pluginRun { return plugins.count > 1 ? "Updating Plugins…" : "Updating Plugin…" }   // [plugin-updates]
        return switch addOns {
        case .push: Self.rowTitle
        case .browser: "Updating Browser Add-on…"
        case .both: "Updating Add-ons…"
        }
    }

    /// Under that row: the step under way, or that the restart is slow.
    var rowStatus: String? {
        guard busy else { return nil }
        if case .ended(let end) = phase { return endHeadline(end) }
        guard let step = steps.first(where: { $0.state == .active }) else { return headline }
        return step.detail.map { "\(step.title): \($0)" } ?? step.title
    }

    /// The big words over the steps.
    var headline: String {
        switch phase {
        case .idle, .checking: return "Checking Hermes…"
        case .asking:
            if pluginRun { return PluginUpdateWords.asking(plugins) }   // [plugin-updates]
            if addOns == .browser { return "Update the Browser Add-on?" }   // [browser-update]
            return setUp ? (both ? "Set Up the Add-ons?" : "Set Up the Add-on?") : (both ? "Update the Add-ons?" : "Update the Add-on?")
        case .working:
            switch steps.first(where: { $0.state == .active })?.id {
            case .restart?: return "Restarting Hermes…"
            case .verify?: return "Almost Done…"
            default: return setUp ? "Setting Up…" : "Updating…"
            }
        case .ended(let end): return endHeadline(end)
        }
    }

    /// [plugin-updates] An ending's big words, for the add-ons or for the plugins this run updated.
    private func endHeadline(_ end: End) -> String {
        pluginRun ? PluginUpdateWords.headline(end, plugins) : Self.headline(end, setUp: setUp, addOns: addOns)
    }

    nonisolated static func headline(_ end: End, setUp: Bool, addOns: AddOns = .push) -> String {
        switch end {
        case .on(let version):
            switch addOns {   // [browser-update]
            case .push: version.map { "Add-on \($0) Is On" } ?? (setUp ? "Add-on Set Up" : "Add-on Updated")
            case .browser: version.map { "Browser Add-on \($0) Is On" } ?? "Browser Add-on Updated"
            case .both: "Both Add-ons Are On"
            }
        case .upToDate: addOns == .push ? "Add-on Is Up to Date" : "Add-ons Are Up to Date"
        case .notOut(_, let want, let browser): browser ? "Browser Add-on \(want) Isn’t Out Yet" : "Add-on \(want) Isn’t Out Yet"
        case .unreachable: "Couldn’t Reach Hermes"
        case .slow: "Hermes Hasn’t Restarted Yet"
        case .yours: "Restart Hermes to Finish"
        case .failed(let title, _), .more(let title, _): title
        }
    }

    /// The line under the headline.
    var line: String? {
        switch phase {
        case .idle, .checking: return nil
        case .asking: return why
        case .working: return Self.keepsGoing
        case .ended(let end):
            if pluginRun, let words = PluginUpdateWords.line(end, plugins) { return words }   // [plugin-updates]
            return Self.line(end, bot: botName, addOns: addOns, push: version, browser: browserVersion)
        }
    }

    nonisolated static let keepsGoing = "You can close this. The update keeps going, and Settings shows how it’s doing."

    /// `push`, `browser`: the versions installed, for the ending of an update of both ([browser-update]).
    nonisolated static func line(_ end: End, bot: String, addOns: AddOns = .push, push: String? = nil, browser: String? = nil) -> String {
        let app = AppIdentity.current.displayName
        switch end {
        case .on:
            switch addOns {   // [browser-update]
            case .push: return "Hermes has the newest add-on for \(app), and every bot has its own copy."
            case .browser: return "Hermes has the browser add-on \(app) needs, so you can watch your bots’ browsers."
            case .both:
                guard let push, let browser else { return "Hermes has the newest add-ons for \(app), and every bot has its own copy." }
                return "Hermes has notification add-on \(push) and browser add-on \(browser), and every bot has its own copy."
            }
        case .upToDate:
            return addOns == .push ? "Hermes and every bot have the add-on \(app) needs. Nothing to do."
                : "Hermes and every bot have the add-ons \(app) needs. Nothing to do."
        case .notOut(let have, let want, true):
            return "This version of \(app) needs browser add-on \(want), but the newest one out is \(have), and Hermes has it now. Nothing needs restarting. Watching a bot’s browser may not work until \(want) is out."
        case .notOut(let have, let want, false):
            return "This version of \(app) needs add-on \(want), but the newest one out is \(have), and Hermes has it now. Nothing needs restarting. Some new features won’t work until \(want) is out."
        case .unreachable: return "Hermes didn’t answer. It may be restarting. Try again in a moment."
        case .slow:
            return "\(bot) may still be working on it, or waiting for an answer from you in its chat. The app keeps watching for 15 minutes and finishes the update once Hermes is back."
        case .yours:
            let what = switch addOns {
            case .push: "The add-on is installed."
            case .browser: "The browser add-on is installed."
            case .both: "Both add-ons are installed."
            }
            return "\(what) Now restart Hermes on its computer (hermes dashboard or hermes serve, and the gateway if it runs on its own). The app finishes once it’s back."
        case .failed(_, let reason), .more(_, let reason): return reason
        }
    }

    /// The steps show while there is something to follow (not for "up to date" or "couldn't reach").
    /// [addon-whats-new] What the update brings, while it's asked and while it goes in.
    var showsChanges: Bool { (phase == .asking || phase == .working) && !changes.isEmpty }

    /// The sheet is as tall as it goes whenever it shows what the update brings (a plugin's card too): fitted to its
    /// rows instead, the List's size lagged them and the steps sat under Update ([addon-sheet-button], seen again with
    /// a plugin's one-row card).
    var fillsHeight: Bool { showsChanges }

    var showsSteps: Bool {
        switch phase {
        case .idle, .checking: return false
        case .asking, .working: return true
        case .ended(let end):
            switch end {
            case .upToDate, .unreachable, .notOut: return false
            case .failed: return steps.contains { $0.id == .install && $0.state == .done }
            case .on, .slow, .yours: return steps.count > 1
            case .more: return steps.contains { $0.id == .install && $0.state == .done }   // steps only when some ran
            }
        }
    }

    /// A button under the steps (Update, Try Again, Open the bot's chat).
    var hasAction: Bool {
        switch phase {
        case .asking, .ended(.unreachable), .ended(.failed), .ended(.slow), .ended(.yours), .ended(.more): true
        default: false
        }
    }

    /// The headline's symbol: nil while working (a spinner).
    var symbol: (name: String, color: Color)? {
        switch phase {
        case .idle, .checking, .working: return nil
        case .asking: return ("puzzlepiece.extension", .hqTint)
        case .ended(let end):
            switch end {
            case .on, .upToDate: return ("checkmark.circle.fill", .green)
            case .notOut: return ("clock.badge.exclamationmark", .orange)
            case .slow: return ("hourglass", .orange)
            case .yours: return ("arrow.clockwise.circle.fill", .hqTint)
            case .more:   // a tick when something went in; otherwise the plugin's own mark (nothing failed, nothing done)
                return steps.contains { $0.id == .install && $0.state == .done } ? ("checkmark.circle.fill", .green) : ("puzzlepiece.extension", .hqTint)
            case .unreachable, .failed: return ("exclamationmark.triangle.fill", .orange)
            }
        }
    }

    nonisolated static func logWord(_ end: End) -> String {
        switch end {
        case .on(let version): "on \(version ?? "?")"
        case .upToDate: "up to date"
        case .notOut(let have, let want, let browser): "not out (\(browser ? "browser " : "")\(have) < \(want))"
        case .unreachable: "unreachable"
        case .slow: "slow restart"
        case .yours: "waiting for the owner's restart"
        case .failed(let title, _): "failed: \(title)"
        case .more(let title, _): "handed on: \(title)"
        }
    }
}

// MARK: - The sheet

final class AddOnUpdateController: UIHostingController<HQScaledRoot<AddOnUpdateView>> {
    private let update: AddOnUpdate

    init(update: AddOnUpdate) {
        self.update = update
        super.init(rootView: HQScaledRoot(AddOnUpdateView(update: update)))
        if let sheet = sheetPresentationController {
            // Tall enough for every step (half height cut the last one off), and large.
            let fit = UISheetPresentationController.Detent.custom(identifier: .init("addon-update.fit")) { [weak self] context in
                guard let self else { return nil }
                // [addon-sheet-button] With what's new it's as tall as it goes (it never fitted below that), from the
                // start: the List's size lagged its lines until a touch, and the sheet grew under that first tap.
                if self.update.fillsHeight { return context.maximumDetentValue }
                return min(context.maximumDetentValue, self.measuredHeight() ?? Self.fitHeight(self.update))
            }
            sheet.detents = [fit, .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()   // [glass-audit] below full height on Liquid Glass, its words on cards
        }
        refitOnChange()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What the sheet shows, in points (below the bar): the headline block, the steps, a button. Body-relative, so it
    /// grows with the text size.
    static func fitHeight(_ update: AddOnUpdate) -> CGFloat {
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1)
        var height: CGFloat = 132 * scale + (update.phase == .asking ? 40 * scale : 0)
        if update.showsSteps { height += 38 + CGFloat(update.steps.count) * 50 * scale + (update.phase == .working ? 30 * scale : 0) }
        if update.hasAction { height += 34 + 52 * scale + (update.offersRestartChoice ? 40 * scale : 0) }
        return height + 56 + 34
    }

    private weak var list: UIScrollView?
    private var listHeight: NSKeyValueObservation?

    /// The list's own height once it has laid out (its bar and the home indicator's inset included), so long words or
    /// a large text size never cut the last step off; until then `fitHeight`'s estimate.
    private func measuredHeight() -> CGFloat? {
        guard let list, list.contentSize.height > 0 else { return nil }
        return ceil(list.contentSize.height + list.adjustedContentInset.top + list.adjustedContentInset.bottom)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard list == nil, let found = Self.firstScrollView(in: view) else { return }
        list = found
        listHeight = found.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refit() }
        }
        refit()
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView { return scroll }
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private var fitted: CGFloat = 0

    /// `settled`: asked again after a change has laid out; the height is taken afresh whatever was fitted before.
    private func refit(settled: Bool = false) {
        // [addon-sheet-button] Not while it goes: the list's insets change as the sheet slides down, and a refit then
        // took the sheet back up (✕ didn't close it).
        guard !isBeingDismissed, presentedViewController == nil else { return }
        UpdateSheetFit.macFit(self, measured: measuredHeight(), fills: update.fillsHeight)   // [Mac UI check 2026-11-13]
        guard let sheet = sheetPresentationController else { return }
        let height = update.fillsHeight ? .greatestFiniteMagnitude : measuredHeight() ?? Self.fitHeight(update)
        guard settled || abs(height - fitted) > 1 else { return }
        fitted = height
        if view.window == nil { sheet.invalidateDetents() } else { sheet.animateChanges { sheet.invalidateDetents() } }
    }

    /// The fitted height follows what's shown (the steps come and go with the phase).
    private func refitOnChange() {
        withObservationTracking {
            _ = update.phase
            _ = update.steps.count
            _ = update.changes
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refit()
                self.refitOnChange()
                // [manual-restart] And once the new state has laid out: the list's size alone doesn't change when the
                // button comes in under it, so a sheet that just shrank from What's New stayed too short for its steps.
                for delay in [0.45, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refit(settled: true) }
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { update.sheetClosed() }
    }
}

struct AddOnUpdateView: View {
    @Bindable var update: AddOnUpdate
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .hqDesktopBareRow()
                if update.showsChanges {
                    ForEach(update.changes) { AddOnChangesSection(item: $0, setUp: update.setUp) }
                }
                if update.showsSteps {
                    Section {
                        ForEach(update.steps) { AddOnStepRow(step: $0) }
                    } footer: {
                        if update.phase == .working { elapsed }
                        else if update.phase == .asking { centeredNote(AddOnUpdate.takesAboutAMinute) }
                    }
                    .hqSheetRows()
                    .hqUpdateSheetRowFit()
                }
            }
            .hqUpdateSheetFit()
            .hqUpdateSheetClearOfButtons()   // [Mac UI check 2026-11-13]
            .hqGroupedPage()
            // [addon-sheet-button] Owner 2026-11-06: a long "what's new" pushed Update below the fold (and a List row
            // off screen isn't even there to tap). The action sits under the list, always in view; the list scrolls.
            .safeAreaInset(edge: .bottom, spacing: 0) {   // not safeAreaBar: its soft edge ate the sheet's taps
                UpdateSheetButtonBar(shown: update.hasAction) { buttons }
            }
            .navigationTitle(update.pluginRun ? (update.plugins.count > 1 ? "Update Plugins" : "Update Plugin")
                             : update.setUp ? (update.both ? "Set Up Add-ons" : "Set Up Add-on") : (update.both ? "Update Add-ons" : "Update Add-on"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar(word: closeWord, id: "addon-update.close") { update.close() } }   // [mac] Mac polish #123
            .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: update.phase)
        }
        .hqGlassSheetPage()
        .accessibilityIdentifier("addon-update")
    }

    /// What the ✕ does, for VoiceOver: hiding the sheet while it works doesn't stop the update. [mac] The Mac's close says it.
    private var closeWord: String {
        switch update.phase {
        case .checking, .working: "Hide"
        case .asking: "Not Now"
        case .idle, .ended: "Done"
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Group {
                if let symbol = update.symbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: symbolSize))
                        .foregroundStyle(symbol.color)
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(height: symbolSize + 4)
            .accessibilityHidden(true)
            Text(update.headline)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("addon-update.headline")
            if let line = update.line {
                Text(line)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color(uiColor: HQPalette.glassInk2))   // [glass-audit] strong ink on the glass
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DeviceWord.isMac ? 440 : nil)   // [mac] a reading width, not the sheet's whole width
                    .accessibilityIdentifier("addon-update.line")
            }
        }
        .frame(maxWidth: .infinity)
        // [mac] Owner 2026-11-07 ("crammed, like we completely forgot to figure out the padding"): room above and below.
        .padding(.top, DeviceWord.isMac && !UpdateSheetFit.on ? 16 : 6)   // [Mac UI check 2026-11-13] less in a short window
        .padding(.bottom, DeviceWord.isMac && !UpdateSheetFit.on ? 12 : 6)
        .contentTransition(.opacity)
    }

    private var elapsed: some View {
        let started = update.steps.first?.started ?? Date()
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(started))))) so far")
                .font(Font.hq(.footnote))
                .monospacedDigit()
                .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    private func centeredNote(_ words: String) -> some View {
        Text(words)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var buttons: some View {
        switch update.phase {
        case .asking:
            VStack(spacing: 0) {
                action(update.setUp ? "Set Up" : "Update", id: "addon-update.go", bottom: update.offersRestartChoice ? 4 : 12) { update.confirm() }
                if update.offersRestartChoice { restartChooser }
            }
        case .ended(.unreachable), .ended(.failed):
            action("Try Again", id: "addon-update.retry") { update.retry() }
        case .ended(.slow):
            action("Open \(update.botName)’s Chat", id: "addon-update.chat") { update.openBotChat() }
        case .ended(.yours):   // [manual-restart]
            action(AddOnUpdate.askInstead(update.botName), id: "addon-update.ask-bot") { update.askBotInstead() }
        case .ended(.more):   // [plugin-ask-bot]
            action(PluginUpdateFlow.shared.handOffButton, id: "addon-update.ask-bot-update") { PluginUpdateFlow.shared.askBotToFinish() }
        default:
            EmptyView()
        }
    }

    /// The sheet's one action, the same wide button in every state so it reads over any picture behind the glass.
    private func action(_ title: String, id: String, bottom: CGFloat = 12, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).frame(maxWidth: GlassSheetKit.designed ? .infinity : nil)
        }
        .hqProminentButtonStyle()
        .controlSize(.large)
        .accessibilityIdentifier(id)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, bottom)
    }

    /// [manual-restart] Under Update, always in view (the steps can be under a long What's New): a switch for
    /// restarting Hermes yourself once the add-on is in. Owner 2026-11-10: a toggle, not a menu.
    private var restartChooser: some View {
        Toggle(isOn: Binding(get: { update.byHand }, set: { update.chooseRestart(byHand: $0) })) {
            Text(AddOnUpdate.byHandToggle)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityIdentifier("addon-update.restart-choice")
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// Mac polish #122, #124: the update sheets' buttons, pinned under their list (Update Add-on, Update Hermes). They sit on
/// the page's own colour with a soft fade above it, so the steps scroll out of sight under them: the iOS look drew Update
/// over the last rows and the card's edge, and the Desktop Look cut the list off hard behind the buttons. On Liquid Glass
/// (a phone's sheet below full height) there is no page colour, so nothing is drawn, as before. With no button the
/// strip isn't there at all: its padding alone drew a block of page colour across "6:55 so far" and What's New's edge.
struct UpdateSheetButtonBar<Buttons: View>: View {
    var shown: Bool
    @ViewBuilder var buttons: Buttons
    @Environment(\.hqGlassSheet) private var glass

    /// The fade's height above the buttons ([sheet-fit] taller on a phone in the look).
    private static var fade: CGFloat { UpdateSheetFit.fade }

    var body: some View {
        if shown {
            let _ = Theme.touch()
            // [plugin-update-run] Owner 2026-11-11, a phone in the iOS look, dark: "doesn't look too great with the
            // black at the bottom". A sheet as tall as it goes still shows the system's glass there, while the glass
            // trait is off, so the page colour drew a black block under Update. In the iOS look on a phone or iPad the
            // strip is frosted instead, which sits on the glass and on a solid sheet alike; the Desktop Look and the
            // Mac keep the page colour their sheets are drawn in.
            let frosted = !glass && !Theme.isDesktop && !DeviceWord.isMac
            let page = glass || frosted ? Color.clear : Color.hqGroupedPage
            buttons
                .frame(maxWidth: .infinity)
                .background {
                    if frosted {
                        Rectangle().fill(.ultraThinMaterial)
                            .padding(.top, -Self.fade)
                            .mask {
                                VStack(spacing: 0) {
                                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                                    Color.black
                                }
                            }
                            .ignoresSafeArea(edges: .bottom)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    } else {
                        page.ignoresSafeArea(edges: .bottom)
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [page.opacity(0), page], startPoint: .top, endPoint: .bottom)
                                    .frame(height: Self.fade)
                                    .offset(y: -Self.fade)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                    }
                }
        }
    }
}

/// [sheet-fit] Owner 2026-11-08 (Desktop Look on an iPhone): the update sheets ran past the screen, "Check it's on"
/// under Update, then What's New's third line cut in half by it. iOS 26 pads a grouped row ~18 pt above and below its
/// words, and the look puts 18 pt between cards and a margin over the headline. On a phone in the look the rows are
/// padded 8 pt, the cards 10 pt apart, the margin gone, Update Hermes lists two of what's new (then "And 4 more."), and
/// anything still under the buttons fades out rather than stopping hard. The Mac's sheets have the room and keep theirs.
enum UpdateSheetFit {
    /// [Mac UI check 2026-11-13] And on the Mac in a window too short for the sheet's whole list (the usual 800 pt
    /// one): the asking states ran What's New and the last step under the pinned Update, a line half faded behind it.
    @MainActor static var on: Bool { Theme.isDesktop && !DeviceWord.isMac || macShort }

    /// [Mac UI check 2026-11-13] The Mac's main window is shorter than the update sheets' full list needs.
    @MainActor static var macShort: Bool {
        DeviceWord.isMac && (MainTabController.current?.viewIfLoaded?.window?.bounds.height ?? .greatestFiniteMagnitude) < 960
    }

    /// How many of Hermes's new commits Update Hermes lists.
    @MainActor static var whatsNewLines: Int { on ? 2 : 5 }

    /// The fade above the buttons.
    @MainActor static var fade: CGFloat { on ? 32 : 16 }
}

extension UpdateSheetFit {
    /// [Mac UI check 2026-11-13] The Mac's update sheets were the fixed tall form sheet (`SheetStyle.macTall`): a short
    /// run (a failure) left ~100 pt of empty sheet over its buttons, a long one faded What's New under Update. The Mac
    /// ignores detents, so the sheet's own size follows its list there: `measured` (the list with its bar and buttons),
    /// between 320 pt and the window's room; `fills` takes the window's room. Nothing off the Mac.
    @MainActor static func macFit(_ controller: UIViewController, measured: CGFloat?, fills: Bool = false) {
        #if targetEnvironment(macCatalyst)
        guard controller.modalPresentationStyle == .formSheet, !controller.isBeingDismissed,
              let window = controller.presentingViewController?.viewIfLoaded?.window else { return }
        let room = max(320, min(window.bounds.height - 80, 1100))
        guard let wanted = fills ? room : measured else { return }
        let height = min(room, max(320, wanted.rounded(.up)))
        guard abs(controller.preferredContentSize.height - height) > 1 else { return }
        controller.preferredContentSize = CGSize(width: controller.preferredContentSize.width, height: height)
        #endif
    }
}

extension View {
    /// [Mac UI check 2026-11-13] On the Mac the list ends a fade's height above the pinned buttons, so its last line
    /// (What's New, a step) clears the fade when scrolled to the end instead of resting half under it.
    @ViewBuilder func hqUpdateSheetClearOfButtons() -> some View {
        if DeviceWord.isMac { contentMargins(.bottom, UpdateSheetFit.fade, for: .scrollContent) } else { self }
    }

    /// On the List, before `hqGroupedPage` (so its section spacing gives way to this one).
    @ViewBuilder func hqUpdateSheetFit() -> some View {
        if UpdateSheetFit.on {
            environment(\.defaultMinListRowHeight, 36)
                .listSectionSpacing(10)
                .contentMargins(.top, 0, for: .scrollContent)
        } else {
            self
        }
    }

    /// On each Section of the sheet's cards.
    @ViewBuilder func hqUpdateSheetRowFit() -> some View {
        if UpdateSheetFit.on { listRowInsets(.vertical, 8) } else { self }
    }
}

/// [addon-whats-new] One add-on in the update: its name and versions ("0.9.33 → 0.9.40"), then a line per newer version.
private struct AddOnChangesSection: View {
    var item: AddOnUpdate.Changing
    var setUp: Bool

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    if let note = item.note {   // [plugin-updates] which bots get it
                        Text(note)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let versions = AddOnUpdate.versions(from: item.from, to: item.to, setUp: setUp) {
                    Text(versions)
                        .font(Font.hq(.subheadline))
                        .monospacedDigit()
                        .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                        .accessibilityIdentifier("addon-update.versions")
                } else if item.loading {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(item.lines, id: \.version) { change in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(change.version)
                        .font(Font.hq(.caption).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(uiColor: HQPalette.glassInk2))
                        .frame(minWidth: 44, alignment: .leading)
                    Text(change.line)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("addon-update.change")
            }
        }
        .hqSheetRows()
        .hqUpdateSheetRowFit()
    }
}

private struct AddOnStepRow: View {
    var step: AddOnUpdate.Step

    private var spokenState: String {
        switch step.state {
        case .done: "Done"
        case .active: "In progress"
        case .skipped: "Not needed"
        case .failed: "Failed"
        case .waiting: "Waiting"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ZStack {
                switch step.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).transition(.hqMotion(.scale.combined(with: .opacity)))
                case .active:
                    ProgressView().controlSize(.small)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(Color.hqLabel3)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Color.hqLabel3)
                case .failed:   // Mac polish #48, as Update Hermes marks its failed step
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
            .font(Font.hq(.title3))
            // [ui-sizing 2026-11-09] As big as the glyph it holds: a fixed 24 pt box let the title3 glyph spill into the
            // step's title at 150 % or a larger text size.
            .frame(width: max(24, HQFont.preferred(.title3).lineHeight), height: max(24, HQFont.preferred(.title3).lineHeight))
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(step.state == .waiting || step.state == .skipped ? Color.hqLabel2 : Color.hqLabel)
                if let detail = step.detail, step.state != .done {
                    Text(detail)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("addon-update.detail.\(step.id.rawValue)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if step.state == .done, let started = step.started, let finished = step.finished {
                Text(CloudCopy.elapsed(max(0, Int(finished.timeIntervalSince(started)))))
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.vertical, 3)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: step.state)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: step.detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(spokenState)
        .accessibilityIdentifier("addon-update.step.\(step.id.rawValue)")
    }
}

#if DEBUG
// MARK: - Pictures of each state (`-HQDebugAddOnUpdate <state>`, App/Debug/DebugHooks.swift)

extension AddOnUpdate {
    /// Puts the sheet in `state` with made-up times: asking, bots, installing, restarting, verifying, on, notout, slow,
    /// unreachable, uptodate, failed. False for a name it doesn't know. [browser-update] `browser-<state>`: the browser
    /// add-on's update alone (3.7.0, switched off, to 3.8.0); `both-<state>`: with the notification add-on's.
    func demo(_ state: String, bot: String, model: AppModel?) -> Bool {
        settleAnswer(false)
        self.model = model
        pluginRun = false
        plugins = []
        // [plugin-updates] `plugin-<state>`: one plugin's update; `plugins-<state>`: three plugins'.
        if state.hasPrefix("plugin-") || state.hasPrefix("plugins-") { return demoPlugins(state, bot: bot) }
        // [manual-restart] `yours`: installed, waiting for the owner's restart; `asking-mine`: the question with
        // the switch on.
        canChooseRestart = true
        byHand = state.hasSuffix("yours") || state.hasSuffix("asking-mine")
        let now = Date()
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let kind: AddOns = state.hasPrefix("browser-") ? .browser : state.hasPrefix("both-") ? .both : .push
        let state = (kind == .push ? state : String(state.drop { $0 != "-" }.dropFirst())).replacingOccurrences(of: "asking-mine", with: "asking")
        let bots = state == "bots"
        botName = bot
        let first = state == "setup" && kind == .push
        setUp = first
        both = first || kind == .both
        addOns = kind
        switch kind {
        case .push: why = Self.why(bots ? .bots(["Finance", "Gym"]) : first ? .missing : .outdated, both: first)
        case .browser: why = Self.why(nil, browser: .off)
        case .both: why = Self.why(bots ? .bots(["Finance", "Gym"]) : .outdated, browser: .off)
        }
        version = kind == .browser ? "3.8.0" : "0.9.32"
        browserVersion = kind == .push ? nil : "3.8.0"
        steps = [
            Step(id: .check, title: Self.checkTitle, state: .done, started: at(74), finished: at(71)),
            Step(id: .install, title: Self.installTitle(setUp: first, both: both, addOns: kind),
                 detail: Self.installPlan(bots: bots ? ["Finance", "Gym"] : [], all: 11, browser: kind == .both)),
            Step(id: .restart, title: Self.restartTitle, detail: byHand ? Self.restartPlanMine : Self.restartPlan(bot)),
            Step(id: .verify, title: Self.verifyTitle(both: both)),
        ]
        // Past the question, a step's plan gives way to what it's doing (as `step(_:_:detail:)` does).
        if !["asking", "bots", "setup"].contains(state) { steps[1].detail = nil }
        func set(_ id: StepID, _ state: StepState, _ detail: String? = nil, from: TimeInterval, to: TimeInterval? = nil) {
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].state = state
            steps[index].detail = detail
            steps[index].started = at(from)
            steps[index].finished = to.map(at)
        }
        watching = false
        // [addon-whats-new] The update's add-ons, versions and lines, as GitHub gives them.
        let pushLines = AddOnChanges.changes(subjects: [
            "hermes-hq-push 0.9.40: after an update the app reads the whole task list again; the add-on says its own version",
            "hermes-hq-push 0.9.39: Task ideas",
            "hermes-hq-push 0.9.38: every task has a Task Page",
            "hermes-hq-push 0.9.37: a task is a workspace — its own chat, what a bot watches for, a check an hour before it's due",
            "hermes-hq-push 0.9.35: Tasks can be turned off entirely (tools hidden, no note, no prep jobs; the list is kept)",
        ], plugin: PushPolicy.pluginName, after: first ? nil : "0.9.34", limit: first ? 2 : 3)
        let browserLines = AddOnChanges.changes(subjects: [
            "hermes-hq-browser 3.8.0: works on Hermes 0.22.6 and newer (browser_exec only) and still on 0.22.5 and older; a plugin reload runs the changed code",
        ], plugin: PushSetupOffer.browserPlugin, after: "3.7.0")
        changes = []
        if kind != .browser {
            changes.append(Changing(plugin: PushPolicy.pluginName, title: Self.pushName, from: first ? nil : "0.9.34", to: "0.9.40",
                                    lines: pushLines, loading: false))
        }
        if kind != .push {
            changes.append(Changing(plugin: PushSetupOffer.browserPlugin, title: Self.browserName, from: "3.7.0", to: "3.8.0",
                                    lines: browserLines, loading: false))
        }
        switch state {
        case "asking", "bots", "setup":
            steps[0] = Step(id: .check, title: Self.checkTitle, state: .done, started: at(4), finished: at(1))
            phase = .asking
        case "installing":
            let line = switch kind {
            case .push: Self.installing("Finance", 4, of: 11)
            case .browser: Self.installing(Self.browserCopy(bot), 1, of: 1)
            case .both: Self.installing(Self.browserCopy(bot), 12, of: 12)
            }
            set(.install, .active, line, from: 22)
            phase = .working
        case "restarting":
            set(.install, .done, from: 71, to: 30)
            set(.restart, .active, Self.botRestarts(bot), from: 30)
            phase = .working
            watching = true
        case "verifying":
            set(.install, .done, from: 71, to: 30)
            set(.restart, .done, from: 30, to: 4)
            set(.verify, .active, kind == .push ? Self.eachBot : Self.browserCheck, from: 4)
            phase = .working
            watching = true
        case "on":
            set(.install, .done, from: 71, to: 30)
            set(.restart, .done, from: 30, to: 4)
            set(.verify, .done, from: 4, to: 1)
            phase = .ended(.on(version: version))
        case "notout":
            set(.install, .done, from: 71, to: 30)
            if kind == .push {
                version = "0.9.31"
                phase = .ended(.notOut(have: "0.9.31", want: "0.9.32"))
            } else {
                browserVersion = "3.7.0"
                phase = .ended(.notOut(have: "3.7.0", want: BrowserAddOn.wantedVersion, browser: true))
            }
        case "slow":
            set(.install, .done, from: 300, to: 260)
            set(.restart, .active, Self.botRestarts(bot), from: 260)
            phase = .ended(.slow)
            watching = true
        case "yours":
            set(.install, .done, from: 71, to: 30)
            set(.restart, .active, Self.youRestart, from: 30)
            phase = .ended(.yours)
            watching = true
        case "unreachable":
            steps = [steps[0]]
            phase = .ended(.unreachable)
        case "uptodate":
            steps = [steps[0]]
            phase = .ended(.upToDate)
        case "failed":
            set(.install, .done, from: 71, to: 30)
            set(.restart, .done, from: 30, to: 4)
            set(.verify, .failed, from: 4, to: 1)   // Mac polish #48: the step that was under way, as a real run marks it
            if kind == .push {
                phase = .ended(.failed(title: Self.stillNeed(["Gym"]), reason: Self.stillNeedReason(count: 1, bot: bot)))
            } else {
                let health: JSONValue = .object(["version": .string("3.8.0"), "protocol": .number(3), "installed": .bool(false),
                                                 "drift": .array([.string("browser tools unavailable (ImportError)")])])
                phase = .ended(.failed(title: Self.browserStillOff, reason: Self.browserStillOffReason(health, bot: bot)))
            }
        default:
            return false
        }
        return true
    }

    /// [plugin-updates] A plugin update's sheet in one state: asking, asking-mine, installing, restarting, on, yours,
    /// slow, uptodate, failed.
    private func demoPlugins(_ state: String, bot: String) -> Bool {
        let several = state.hasPrefix("plugins-")
        let state = String(state.drop { $0 != "-" }.dropFirst())
        canChooseRestart = true
        byHand = state == "yours" || state == "asking-mine"
        let now = Date()
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        beginPluginsForDemo()
        var cards = [Changing(plugin: "web-clipper", title: "web-clipper", from: "1.4.2", to: "1.5.0", loading: false,
                              note: several ? "For \(bot) and Finance" : nil)]
        if several {
            cards.append(Changing(plugin: "field-notes", title: "field-notes", from: "0.8.0", to: "0.9.1", loading: false, note: "For \(bot)"))
            cards.append(Changing(plugin: "spotify", title: "spotify", from: "2.1.0", to: "9f2c1ab", loading: false, note: "For Gym"))
        }
        let names = cards.map(\.plugin)
        foundPlugins(names, why: PluginUpdateWords.why(names), bot: bot, installNote: nil, cards: cards)
        func set(_ id: StepID, _ state: StepState, _ detail: String? = nil, from: TimeInterval, to: TimeInterval? = nil) {
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].state = state
            steps[index].detail = detail
            steps[index].started = at(from)
            steps[index].finished = to.map(at)
        }
        set(.check, .done, from: 40, to: 37)
        watching = false
        switch state {
        case "asking", "asking-mine":
            set(.check, .done, from: 4, to: 1)
            phase = .asking
        case "installing":
            set(.install, .active, Self.installing(several ? "field-notes for \(bot)" : "web-clipper", several ? 3 : 1, of: several ? 4 : 1), from: 12)
            phase = .working
        case "restarting":
            set(.install, .done, from: 37, to: 30)
            set(.restart, .active, Self.botRestarts(bot), from: 30)
            phase = .working
            watching = true
        case "on":
            set(.install, .done, from: 37, to: 30)
            set(.restart, .done, from: 30, to: 4)
            set(.verify, .done, from: 4, to: 1)
            phase = .ended(.on(version: nil))
        case "yours":
            set(.install, .done, from: 37, to: 30)
            set(.restart, .active, Self.youRestart, from: 30)
            phase = .ended(.yours)
            watching = true
        case "slow":
            set(.install, .done, from: 300, to: 260)
            set(.restart, .active, Self.botRestarts(bot), from: 260)
            phase = .ended(.slow)
            watching = true
        case "uptodate":
            steps = [steps[0]]
            changes = []
            phase = .ended(.upToDate)
        case "failed":
            set(.install, .failed, from: 37, to: 30)
            phase = .ended(.failed(title: PluginUpdateWords.couldnt(["web-clipper"]), reason: PluginUpdateWords.scanBlocked))
        default:
            return false
        }
        return true
    }

    private func beginPluginsForDemo() {
        pluginRun = true
        setUp = false
        both = false
        addOns = .push
        steps = [Step(id: .check, title: Self.checkTitle, state: .active, started: Date())]
    }
}
#endif
