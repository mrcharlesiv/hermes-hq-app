// Notifications need the hermes-hq-push plugin on the gateway (port of the web app's push-setup.ts, build 240). Nobody
// should have to find a terminal for that: when the signed-in gateway lacks it, or has one too old, the app offers to
// install it through Hermes's plugin manager (plugins.manage) and have the gateway's own main bot restart the web
// server, or, where the manager can't be used, have the main bot install it (its chat opens and the request is queued there, as Watch Browser's "Ask Hermes
// to Install It" does), then watches for the plugin to come up (15 min) and registers. Asked at launch once per add-on
// level a build asks for (PushPolicy.offerLevel), per gateway account; after Not Now, AddOnReminder reminds quietly on
// every launch (a count on the tab holding Settings, a row at the top of Settings) and Settings asks again on demand. Only in a build push can reach (AppIdentity).
// Every bot gets its own copy (Hermes loads a bot's add-ons from that bot's folder only): with the main bot's copy
// current, a bot without its own, or with one older than PushPolicy.everyBotVersion, makes the offer an update.
// [browser-update] The same check reads the browser add-on's /health: an installed hermes-hq-browser older than
// BrowserAddOn.wantedVersion (or switched off by Hermes for being older) is updated by the same sheet, alone or in the
// notification add-on's install pass, with the one restart reloading both.

import UIKit
import UserNotifications

@MainActor final class PushSetupOffer {
    static let shared = PushSetupOffer()

    static let pluginSource = "mrcharlesiv/hermes-hq-plugins/hermes-hq-push"
    static let oldPlugin = "dispatch-push"

    /// Who is asking and what for, ahead of every request: a bot shown a bare install command and a restart for an app
    /// it has never heard of read it as an injection and refused (owner, 2026-10-14, a freshly set-up gateway).
    nonisolated static var whoAsks: String {
        let app = AppIdentity.current.displayName
        return "This is from me, through \(app), the \(DeviceWord.name) app I'm chatting with you in; it connects to this Hermes's web dashboard. "
            + "So it can alert my \(DeviceWord.name) when a bot replies or needs an approval, it uses its notification plugin, hermes-hq-push, "
            + "which I publish myself at https://github.com/\(repo) (the hermes-hq-push folder)."
    }

    nonisolated static let repo = "mrcharlesiv/hermes-hq-plugins"

    /// The restart, once only (the web server loads a plugin's routes when it starts).
    nonisolated static var restartStep: String {
        let app = AppIdentity.current.displayName
        return """
        Hermes loads a plugin's web routes only when its web server starts, and its fixes when a gateway starts, so the server \(app) connects to (hermes dashboard or hermes serve) needs one restart, and so does the messaging gateway (hermes gateway) if one runs as its own service. Find how each runs first (hermes dashboard --status, and whether a launchd, systemd or other service manages it), then restart each the same way, keeping its arguments and profile. The restart drops this chat for a moment, so tell me before you do it and start it in the background about 15 seconds after your reply (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). Run it once only: not through launchctl submit, a LaunchAgent, cron or a timer, which would restart it again and again and keep Hermes down. Don't restart anything else.
        """
    }

    /// The whole job, when the app can't install the plugin itself (push-setup.ts PUSH_SETUP_PROMPT, with who asks and
    /// an honest stop for a Hermes without `hermes plugins`).
    static var prompt: String {
        let app = AppIdentity.current.displayName
        return """
        \(whoAsks) Please install it here with your terminal tools; ask me only for what you can't do.

        1. Install it: hermes plugins install \(pluginSource) --enable
        If it's already installed, run the same command with --force added, to replace the older copy (its registered phones are kept). If this Hermes has no hermes plugins command, don't look for another way in: tell me its version (hermes --version) and stop, since Hermes likely needs updating first. If Hermes's security scan flags the plugin, show me what it found and wait for my answer.

        2. Install it for every other bot too: Hermes loads a bot's plugins from that bot's own folder only, so a bot without its own copy can't alert me about its approvals or questions. For each profile hermes profile list shows besides default, run the same command for that profile: hermes -p <profile> plugins install \(pluginSource) --enable (with --force where it's already installed).

        3. If the older \(oldPlugin) plugin (this plugin's previous name) is installed in any of them, remove it there so only one sends alerts: hermes plugins remove \(oldPlugin) (hermes -p <profile> plugins remove \(oldPlugin) for another profile). The new plugin carries over the phones the old one had registered.

        4. Check it: hermes plugins list --enabled, and hermes -p <profile> plugins list --enabled for each profile, should list hermes-hq-push, version \(PushPolicy.everyBotVersion) or newer, and no \(oldPlugin).

        5. \(restartStep)

        When you're done, tell me in a sentence or two what you did. You don't need to test an alert: \(app) checks for the plugin itself and turns notifications on.
        """
    }

    /// [browser-update] Who is asking when only the browser add-on is updated (`whoAsks` is about notifications).
    nonisolated static var browserWhoAsks: String {
        let app = AppIdentity.current.displayName
        return "This is from me, through \(app), the \(DeviceWord.name) app I'm chatting with you in; it connects to this Hermes's web dashboard. "
            + "So I can watch a bot's browser live and take it over when it needs me, it uses its browser plugin, \(browserPlugin), "
            + "which I publish myself at https://github.com/\(repo) (the \(browserPlugin) folder)."
    }

    /// The app installed the plugin through Hermes's plugin manager; only the restart is left for the bot.
    /// `browser`: Watch Browser's plugin went in with it (a first setup), so the one restart loads both, and the bot
    /// says whether this computer has a Chrome for it (the app can't see that before the install).
    /// [browser-update] `browserUpdate`: the browser plugin's update went in too (`push` false: only it did), so the
    /// one restart loads it, and it brings every other bot's copy up to date itself.
    static func restartPrompt(browser: Bool = false, browserUpdate: Bool = false, push: Bool = true) -> String {
        let app = AppIdentity.current.displayName
        if browserUpdate {
            let want = BrowserAddOn.wantedVersion
            let lead = push
                ? "\(whoAsks) It also uses its browser plugin, \(browserPlugin) (the \(browserPlugin) folder of the same repository), so I can watch a bot's browser live. \(app) has just installed both through Hermes's own plugin manager (plugins.manage), so they should show in hermes plugins list, \(browserPlugin) at version \(want) or newer."
                : "\(browserWhoAsks) \(app) has just updated it to version \(want) through Hermes's own plugin manager (plugins.manage), for the main profile, so it should show in hermes plugins list."
            return """
            \(lead) Once the server restarts, the browser plugin brings its copy in every other bot up to date itself, so don't update it per profile.

            \(restartStep)

            When you're done, tell me in a sentence what you did. \(app) checks for the \(push ? "plugins" : "plugin") itself.
            """
        }
        guard browser else {
            return """
            \(whoAsks) \(app) has just installed it through Hermes's own plugin manager (plugins.manage), so it should show in hermes plugins list.

            \(restartStep)

            When you're done, tell me in a sentence what you did. \(app) checks for the plugin itself and turns notifications on.
            """
        }
        return """
        \(whoAsks) It also uses its browser plugin, \(browserPlugin) (the \(browserPlugin) folder of the same repository), so I can watch a bot's browser live and take it over when it needs me to sign in. \(app) has just installed both through Hermes's own plugin manager (plugins.manage), for the main profile, so they should show in hermes plugins list. Once the server restarts, the browser plugin adds itself to every other bot and gives each its own headless Chrome, so don't install it per profile.

        1. Check for a browser: the browser plugin runs Google Chrome, Chromium, Brave or Edge, else Playwright's Chromium. If none of them is on this computer, tell me, and don't install one unless I ask.

        2. \(restartStep)

        When you're done, tell me in a sentence or two what you did. \(app) checks for the plugins itself and turns notifications on.
        """
    }

    nonisolated static var restartTitle: String { "Restart Hermes so the \(AppIdentity.current.displayName) notification add-on loads." }
    nonisolated static var bothRestartTitle: String { "Restart Hermes so the \(AppIdentity.current.displayName) add-ons load." }
    /// [browser-update] Only the browser add-on's update went in.
    nonisolated static var browserRestartTitle: String { "Restart Hermes so the \(AppIdentity.current.displayName) browser add-on loads." }

    /// [setup-browser] Watch Browser's plugin, added with a first setup (owner 2026-11-02: a fresh gateway shouldn't
    /// wait to be asked). Not on Hermes Cloud: its bots browse in Browser Use's cloud, which the plugin can't show.
    nonisolated static let browserPlugin = "hermes-hq-browser"

    /// What the bubble and the queue row say (push-setup.ts QUEUE_TITLE).
    nonisolated static var queueTitle: String { "Install the \(AppIdentity.current.displayName) notification add-on on this Hermes." }

    /// [addon-reminder] Account → the `PushPolicy.offerLevel` the launch alert last offered (was a weekly time).
    private static let offeredKey = "hermes.pushSetup.offeredLevel"
    private var running = false
    private var watch: Task<Void, Never>?
    /// [addon-progress] The watch whose end says the sheet is no longer waiting (a newer watch takes over).
    private var watchToken: UUID?
    private var launchCheck: Task<Void, Never>?

    /// Offer setup? Only for a plugin that is missing or too old: at launch once per add-on level (`offered` is the
    /// level last offered to this account), from Settings whenever asked.
    /// [browser-update] `browser`: the browser add-on needs its update, offered at launch once per version it's
    /// updated to (`browserOffered` is the one last offered).
    nonisolated static func shouldOffer(state: PushPolicy.PluginState, browser: Bool = false, account: String?, offered: String?,
                                        browserOffered: String? = nil, level: String = PushPolicy.offerLevel,
                                        browserLevel: String = BrowserAddOn.wantedVersion, fromSettings: Bool) -> Bool {
        let push = state == .missing || state == .outdated
        guard push || browser, let account, !account.isEmpty else { return false }
        return fromSettings || (push && offered != level) || (browser && browserOffered != browserLevel)
    }

    /// [browser-update] Account → the browser add-on version the launch sheet last offered.
    private static let browserOfferedKey = "hermes.browserUpdate.offeredLevel"

    private func offered(_ account: String, key: String = PushSetupOffer.offeredKey) -> String? {
        UserDefaults.standard.dictionary(forKey: key)?[account] as? String
    }

    private func remember(_ account: String, level: String?, key: String = PushSetupOffer.offeredKey) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[account] = level
        UserDefaults.standard.set(all, forKey: key)
    }

    /// A sign-out or switch: nothing pending for the old account.
    func reset() {
        launchCheck?.cancel(); launchCheck = nil
        watch?.cancel(); watch = nil; watchToken = nil
        pendingAsk = nil
        running = false
        PluginUpdateFlow.shared.reset()   // [plugin-updates] its watch too: the sheet is the same one
        AddOnUpdate.shared.reset()
    }

    /// After launch: once the roster is there (≤ 30 s), offer setup if the plugin is missing or old.
    func afterLaunch(model: AppModel) {
        guard PushRegistrar.available else { return }
        launchCheck?.cancel()
        launchCheck = Task { @MainActor [weak model] in
            for _ in 0..<30 {
                if let model, model.botsLoaded, !model.bots.isEmpty { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let model else { return }
            await self.check(model: model, fromSettings: false, from: nil)
        }
    }

    /// The main bot (the gateway's default profile), which runs where Hermes is installed.
    static func setupBot(_ bots: [Bot]) -> Bot? { bots.first { $0.id == "default" } }

    /// What going ahead does besides the install (UX study #137): the restart, and the main bot's chat opening with the
    /// request when the bot has to help. The offer's alert ends with it; Settings' footer says it under Ask… (#139).
    nonisolated static func restartNote(bot: String, byHand: Bool = false) -> String {
        // [manual-restart] The owner restarts Hermes themselves: the chat opens only when the bot has to install it.
        if byHand { return "Then you restart Hermes on its computer, and the app finishes once it’s back." }
        return "Hermes restarts for a moment. If \(bot) has to help, \(bot)’s chat opens with the request."
    }

    /// `confirm`: false when the person already asked for this in so many words (Settings' "Ask <bot> to Install It"),
    /// so the offer's own alert would only ask again (UX study #139). The Enable switch and the launch offer keep it.
    /// `needsIdeas`: the Ideas page's Update Add-on. An add-on the app otherwise calls current (0.9.32+) but without
    /// Ideas (before 0.9.39) is updated too; it used to say Up to Date and change nothing.
    @discardableResult
    func check(model: AppModel, fromSettings: Bool, confirm: Bool = true, needsIdeas: Bool = false,
               from presenter: UIViewController?) async -> Bool {
        guard PushRegistrar.available else { return false }
        let update = AddOnUpdate.shared
        // [addon-progress] A tap while an update (or the check before it, or the wait for the restart) is under way
        // brings it back into view. It used to return here without a word: the tap's buzz and nothing else.
        if fromSettings, update.busy {
            AppLog.note("push", "update sheet: shown again")
            update.show(from: presenter)
            return false
        }
        // The launch check is still reading Hermes: the sheet opens now, and this tap's check follows it unless that
        // one goes on to update (then the sheet shows its steps).
        if fromSettings, running {
            update.begin(model: model)
            update.show(from: presenter)
            for _ in 0..<60 where running { try? await Task.sleep(for: .milliseconds(500)) }
            guard !running, update.phase == .checking else {
                if running { update.end(.unreachable) }
                return false
            }
        }
        guard !running else { return false }
        // [plugin-updates] The launch check doesn't take the sheet from a plugin update under way.
        if !fromSettings, update.busy, update.pluginRun { return false }
        #if DEBUG
        // Films of other pages (`-HQDebugNoPushOffer YES`): no launch alert over them.
        if !fromSettings, UserDefaults.standard.bool(forKey: "HQDebugNoPushOffer") { return false }
        #endif
        running = true
        defer { running = false }
        // [addon-progress] Asked for (a row, a button, a switch): the sheet is up before the first read goes out.
        if fromSettings {
            update.begin(model: model)
            update.show(from: presenter)
        }
        let answer = await PushRegistrar.shared.pluginState()
        guard let account = PushRegistrar.shared.owner else {
            if fromSettings { update.end(.unreachable) }
            return false
        }
        let store = model.settingsHub.capabilitiesStore
        var state = answer.state, without: [Bot] = []
        if needsIdeas, state == .ready, !PushRegistrar.shared.taskIdeasServed { state = .outdated }
        // The main bot's copy is current: the other bots each need their own.
        if state == .ready {
            if fromSettings { update.detail(.check, AddOnUpdate.eachBot) }
            without = await Self.botsWithout(store: store, bots: model.bots, fresh: fromSettings)
            if !without.isEmpty { state = .outdated }
        }
        // [browser-update] The browser add-on's own answer (not asked when Hermes didn't answer the first read).
        let browserRead = answer.state == .unknown ? BrowserRead.unknown : await Self.readBrowser(model.browser)
        let browserNeed = browserRead.need
        // [addon-reminder] The quiet reminder follows every answer, whether or not the alert shows.
        if let id = model.account?.id {
            AddOnReminder.shared.report(account: id, state: answer.state, without: without.map(\.name))
            if browserRead != .unknown { AddOnReminder.shared.reportBrowser(account: id, need: browserNeed) }
        }
        let pushWork = state == .missing || state == .outdated
        // [addon-progress] Nothing to do, or no answer: said in the sheet, not left to the person to guess.
        if fromSettings, !pushWork, browserNeed == nil {
            update.checked(browser: browserRead == .current)
            update.end(state == .ready ? .upToDate : .unreachable)
            return false
        }
        guard Self.shouldOffer(state: state, browser: browserNeed != nil, account: account, offered: offered(account),
                               browserOffered: offered(account, key: Self.browserOfferedKey), fromSettings: fromSettings) else {
            if fromSettings { update.reset() }
            return false
        }
        guard let bot = Self.setupBot(model.bots) else {
            if fromSettings { update.end(.failed(title: "Couldn’t Start the Update", reason: MainBotRequest.noMainBot)) }
            return false
        }
        guard MemoController.shared.takeId == nil, let host = FailureAlert.topmost(presenter ?? MainTabController.current) else {
            if fromSettings { update.reset() }
            return false
        }
        if pushWork { remember(account, level: PushPolicy.offerLevel) }
        if browserNeed != nil { remember(account, level: BrowserAddOn.wantedVersion, key: Self.browserOfferedKey) }
        let outdated = state == .outdated
        // [setup-browser] A first setup (no notification add-on yet) brings Watch Browser's add-on too.
        let browser = Self.bringsBrowser(state: state, gateway: model.account?.baseURL) ? await Self.browserMissing(store: store) : false
        // [browser-update] The browser add-on's update, alone or in the same pass.
        let browserUpdate = browserNeed != nil
        let need: AddOnReminder.Need? = pushWork ? AddOnReminder.need(state: answer.state, without: without.map(\.name)) ?? (outdated ? .outdated : .missing) : nil
        // [addon-progress] Asked in the sheet, from Settings and at launch alike: one line on what the add-on is and why,
        // and the steps saying what will happen (the launch alert was a paragraph the owner found too much to read).
        if !fromSettings { update.begin(model: model) }
        let why = browserNeed.map { AddOnUpdate.why(need, browser: $0) } ?? need.map { AddOnUpdate.why($0, both: browser) } ?? ""
        update.found(setUp: pushWork && !outdated, why: why, bot: bot.name, both: browser || (pushWork && browserUpdate), browserOnly: !pushWork,
                     installNote: AddOnUpdate.installPlan(bots: without.map(\.name), all: model.bots.count, browser: pushWork && browserUpdate))
        update.loadChanges(store: store)   // [addon-whats-new] which versions, and what they bring
        if confirm {
            let go = await update.ask(presenting: fromSettings ? nil : host)
            AppLog.note("push", go ? "setup asked" : "setup declined")
            guard go else { return false }
        } else if !fromSettings {
            update.show(from: host)
        }
        update.work()
        update.step(.install, .active)
        // [browser-update] Only the browser add-on: its own install, restart and check.
        guard pushWork else { return await updateBrowserOnly(model: model, bot: bot, store: store) }
        // The app installs the plugin itself through Hermes's plugin manager; the bot is asked only for what the app
        // can't do (the web server's restart), or for the whole job when the manager isn't there to use.
        var text = Self.prompt, queueTitle = Self.queueTitle
        let names = Dictionary(model.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let replacesMain = without.isEmpty
        // [browser-update] The browser add-on's copy is counted last ("n of N" runs on into it).
        let extra = browserUpdate ? 1 : 0
        var installed = await Self.installDirectly(store: store, force: outdated, main: replacesMain, others: model.bots.map(\.id),
                                                   needsIdeas: needsIdeas) { progress in
            switch progress {
            case .bot(let id, let index, let total): update.detail(.install, AddOnUpdate.installing(names[id] ?? id, index, of: total + extra))
            case .loading: update.detail(.install, AddOnUpdate.loading)
            case .version(let version): update.installed(version: version)
            }
        }
        // [setup-browser] Its hooks load only when the gateways start, so a browser add-on put in always asks the restart.
        let browserIn = browser && (installed == .ready || installed == .needsRestart) ? await Self.installBrowser(store: store) : false
        // [browser-update] The browser add-on's update goes in with it, so the one restart loads both. Where the bot
        // does the notification add-on's whole job, its restart reloads the browser add-on too.
        var browserUpdated = false
        if browserUpdate, [.ready, .needsRestart, .unavailable].contains(installed) {
            let count = Self.installCount(main: replacesMain, bots: model.bots) + 1
            update.detail(.install, AddOnUpdate.installing(AddOnUpdate.browserCopy(bot.name), count, of: count))
            switch await Self.updateBrowser(store: store) {
            case .installed(let version):
                browserUpdated = true
                update.installed(browser: version)
            case .notOut(let have, let want):
                AppLog.note("push", "setup: newest browser add-on out \(have) < \(want), left as it is")
            case .unavailable:
                break
            }
        }
        // The sheet's words follow what went in: the notification add-on alone when the browser add-on's update didn't.
        if browserUpdate, !browserUpdated { update.only(.push) }
        installed = Self.afterInstall(installed, browserIn: browserIn, browserUpdated: browserUpdated)
        if browserUpdated, case .notOut(let have, let want) = installed {
            // [browser-update] The newest notification add-on out is older than this build asks for, but the browser
            // add-on's update went in: the restart is still needed for it, and the sheet follows the browser add-on.
            AppLog.note("push", "setup: newest add-on out \(have) < \(want), browser add-on updated, restart asked")
            if let id = model.account?.id { AddOnReminder.shared.noteNotOut(account: id, want: want) }
            update.only(.browser)
            return await restartForBrowser(model: model, bot: bot, viaManager: true)
        }
        switch installed {
        case .tooOld:
            AppLog.note("push", "setup: no plugin manager")
            update.end(.failed(title: "Update Hermes First",
                               reason: "This Hermes is too old to add plugins, so notifications can’t be set up yet. Update Hermes on that computer, then try again from Settings › Notifications."))
            return false
        case .notOut(let have, let want):
            // [addon-progress] The newest add-on out is older than this build asks for. A restart can't fix that, so
            // none is asked for (the owner's test gateway got 0.9.31 for a build wanting 0.9.32, restarted, and was
            // still told an update was there).
            AppLog.note("push", "setup: newest add-on out \(have) < \(want), no restart asked")
            update.step(.install, .done)
            update.end(.notOut(have: have, want: want))
            if let id = model.account?.id { AddOnReminder.shared.noteNotOut(account: id, want: want) }
            return false
        case .ready:
            AppLog.note("push", "setup: installed, routes up")
            update.step(.install, .done)
            update.step(.restart, .skipped, detail: AddOnUpdate.notNeeded)
            update.step(.verify, .done)
            if let id = model.account?.id { AddOnReminder.shared.report(account: id, state: .ready, without: []) }
            update.end(.on(version: update.version))
            let granted = await AppModel.requestPermission()
            AppLog.note("push", granted ? "setup done, alerts on" : "setup done, alerts off in iOS")
            return true
        case .needsRestart:
            AppLog.note("push", "setup: installed, restart asked\(browserUpdated ? " (browser add-on updated too)" : "")")
            text = Self.restartPrompt(browser: browserIn, browserUpdate: browserUpdated)
            queueTitle = browserIn || browserUpdated ? Self.bothRestartTitle : Self.restartTitle
            update.step(.install, .done)
            // [manual-restart] The owner restarts Hermes themselves: no chat opens, the sheet says what's left.
            if update.byHand {
                leaveRestart(PendingAsk(bot: bot, text: text, title: queueTitle, retryHint: "Try again from Settings › Notifications.",
                                        account: model.account?.id, mainReplaced: replacesMain, push: true, browser: browserUpdated), model: model)
                return true
            }
            update.step(.restart, .active, detail: AddOnUpdate.botRestarts(bot.name))
        case .unavailable:
            AppLog.note("push", "setup: manager refused, bot asked")
            update.detail(.install, AddOnUpdate.botInstalls(bot.name))
        }
        // [settings] Queued in the main bot's chat (sent at once when it is free), the bubble showing the short title.
        // [addon-progress] The sheet stays over the chat as it opens (at half height the request shows above it).
        guard await ask(bot: bot, text: text, title: queueTitle, retryHint: "Try again from Settings › Notifications.") else { return false }
        watchForPlugin(name: bot.name, account: model.account?.id, model: model, mainReplaced: replacesMain && installed != .unavailable,
                       browser: browserUpdated)
        return true
    }

    // MARK: The owner restarts Hermes ([manual-restart])

    /// The restart request that wasn't sent, kept so "Ask <bot> Instead" can send it, with what the watch looks for.
    struct PendingAsk {
        var bot: Bot
        var text: String
        var title: String
        var retryHint: String
        var account: String?
        var mainReplaced: Bool
        var push: Bool
        var browser: Bool
    }

    private var pendingAsk: PendingAsk?
    private weak var pendingModel: AppModel?

    /// How long the app watches for a restart the owner does themselves (they may have to get to that computer).
    nonisolated static let byHandWatch: TimeInterval = 24 * 60 * 60

    /// Installed, and the restart is the owner's: the sheet ends on "Restart Hermes to Finish" and the app watches.
    private func leaveRestart(_ pending: PendingAsk, model: AppModel) {
        let update = AddOnUpdate.shared
        AppLog.note("push", "setup: restart left to the owner")
        pendingAsk = pending
        pendingModel = model
        update.step(.restart, .active, detail: AddOnUpdate.youRestart)
        update.end(.yours)
        update.show(from: nil)
        watchForPlugin(name: pending.bot.name, account: pending.account, model: model, mainReplaced: pending.mainReplaced,
                       push: pending.push, browser: pending.browser, byHand: true, deadline: Date().addingTimeInterval(Self.byHandWatch))
    }

    /// "Ask <bot> Instead": the kept request goes to the main bot's chat, and the watch starts over as the bot's.
    func askBotInstead() {
        guard let pending = pendingAsk else { return }
        pendingAsk = nil
        let update = AddOnUpdate.shared
        AppLog.note("push", "setup: restart asked of the bot instead")
        Task { @MainActor [weak self] in
            guard let self else { return }
            update.work()
            update.step(.restart, .active, detail: AddOnUpdate.botRestarts(pending.bot.name))
            // Not sent: the sheet says why, and the watch for the owner's own restart goes on.
            guard await self.ask(bot: pending.bot, text: pending.text, title: pending.title, retryHint: pending.retryHint) else { return }
            self.watchForPlugin(name: pending.bot.name, account: pending.account, model: self.pendingModel, mainReplaced: pending.mainReplaced,
                                push: pending.push, browser: pending.browser)
        }
    }

    /// Queues the request in the main bot's chat with the sheet kept over it; a failure ends the sheet in words.
    private func ask(bot: Bot, text: String, title: String, retryHint: String) async -> Bool {
        let update = AddOnUpdate.shared
        do {
            try await MainBotRequest.queue(text: text, title: title, retryHint: retryHint, keeping: update.shownSheet)
        } catch {
            AppLog.note("push", "setup request not queued")
            update.end(.failed(title: "Couldn’t Ask \(bot.name)", reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            update.show(from: nil)
            return false
        }
        update.show(from: nil)
        return true
    }

    // MARK: The browser add-on's update ([browser-update])

    /// What the browser add-on's /health says about updating it.
    enum BrowserRead: Equatable, Sendable {
        /// No answer (Hermes away, a timeout): the reminder is left as it is.
        case unknown
        /// No browser add-on, or only the old dispatch-browser (Watch Browser's own request moves that one over).
        case absent
        /// Installed and nothing an update can do (an older test plugin, or current but off all the same).
        case other
        /// At this build's version and on.
        case current
        case need(BrowserAddOn.Need)

        var need: BrowserAddOn.Need? { if case .need(let need) = self { need } else { nil } }

        static func from(_ plugin: BrowserService.Plugin) -> BrowserRead {
            if plugin.legacy { return .absent }
            if let need = BrowserAddOn.need(plugin.health) { return .need(need) }
            return BrowserAddOn.isOn(plugin.health) ? .current : .other
        }
    }

    static func readBrowser(_ service: BrowserService?) async -> BrowserRead {
        guard let service else { return .unknown }
        do { return .from(try await service.plugin(fresh: true)) } catch {
            return BrowserService.isMissing(error) ? .absent : .unknown
        }
    }

    /// How the browser add-on's update went in.
    enum BrowserInstall: Equatable, Sendable {
        /// Installed (its version, when the list gave one): it loads with the next restart.
        case installed(String?)
        /// The newest one out (`have`) is still older than this build asks for (`want`).
        case notOut(have: String, want: String)
        /// The manager refused, wants consent, or isn't there: the main bot is asked.
        case unavailable
    }

    /// `plugins.manage` installs hermes-hq-browser over the main profile's copy (forced, switched on), then its version
    /// is read back. Only the main profile: once Hermes restarts, the add-on brings every other bot's copy up to date.
    static func updateBrowser(store: CapabilitiesStore?) async -> BrowserInstall {
        guard let store,
              let result = try? await store.plugin(.install(identifier: BrowserSetupPrompt.source, force: true, enable: true, ref: nil), profile: "default"),
              result.ok || result.name != nil, !result.consentRequired else {
            AppLog.note("push", "setup: browser add-on update not installed")
            return .unavailable
        }
        let copy = try? await store.plugins("default").first { $0.name == browserPlugin }
        guard let version = copy?.version, PushPolicy.versionAtLeast(version, "0") else {
            AppLog.note("push", "setup: browser add-on updated")
            return .installed(nil)
        }
        AppLog.note("push", "setup: browser add-on \(version) installed")
        let want = BrowserAddOn.wantedVersion
        return PushPolicy.versionAtLeast(version, want) ? .installed(version) : .notOut(have: version, want: want)
    }

    /// How many bots the notification add-on's install counts (installDirectly's `total`): the browser add-on's copy
    /// is the one after them.
    nonisolated static func installCount(main: Bool, bots: [Bot]) -> Int {
        (main ? 1 : 0) + bots.filter { $0.id != "default" }.count
    }

    /// The browser add-on's update alone: installed, the restart asked of the main bot (or the whole update, where
    /// the manager can't be used), then watched for as the notification add-on's is.
    private func updateBrowserOnly(model: AppModel, bot: Bot, store: CapabilitiesStore?) async -> Bool {
        let update = AddOnUpdate.shared
        update.detail(.install, AddOnUpdate.installing(AddOnUpdate.browserCopy(bot.name), 1, of: 1))
        switch await Self.updateBrowser(store: store) {
        case .notOut(let have, let want):
            AppLog.note("push", "setup: newest browser add-on out \(have) < \(want), no restart asked")
            update.installed(browser: have)
            update.step(.install, .done)
            update.end(.notOut(have: have, want: want, browser: true))
            return false
        case .installed(let version):
            update.installed(browser: version)
            return await restartForBrowser(model: model, bot: bot, viaManager: true)
        case .unavailable:
            return await restartForBrowser(model: model, bot: bot, viaManager: false)
        }
    }

    /// The browser add-on's restart (`viaManager`: it went in; otherwise the bot is asked to update it, restart and all).
    private func restartForBrowser(model: AppModel, bot: Bot, viaManager: Bool) async -> Bool {
        let update = AddOnUpdate.shared
        let text: String, title: String
        if viaManager {
            AppLog.note("push", "setup: browser add-on installed, restart asked")
            text = Self.restartPrompt(browserUpdate: true, push: false)
            title = Self.browserRestartTitle
            update.step(.install, .done)
            if update.byHand {   // [manual-restart]
                leaveRestart(PendingAsk(bot: bot, text: text, title: title, retryHint: "Try again from Settings.",
                                        account: model.account?.id, mainReplaced: false, push: false, browser: true), model: model)
                return true
            }
            update.step(.restart, .active, detail: AddOnUpdate.botRestarts(bot.name))
        } else {
            AppLog.note("push", "setup: manager refused the browser add-on, bot asked")
            text = BrowserSetupPrompt.update
            title = MainBotRequest.browserUpdateTitle
            update.detail(.install, AddOnUpdate.botInstalls(bot.name))
        }
        guard await ask(bot: bot, text: text, title: title, retryHint: "Try again from Settings.") else { return false }
        watchForPlugin(name: bot.name, account: model.account?.id, model: model, mainReplaced: false, push: false, browser: true)
        return true
    }

    /// [browser-update] One restart for everything the pass put in: a browser add-on that went in (a first setup's, or
    /// its update) loads only with a restart, so routes already up don't end the run early.
    nonisolated static func afterInstall(_ installed: DirectInstall, browserIn: Bool, browserUpdated: Bool) -> DirectInstall {
        (browserIn || browserUpdated) && installed == .ready ? .needsRestart : installed
    }

    nonisolated enum DirectInstall: Equatable {
        case tooOld, ready, needsRestart, unavailable
        /// [addon-progress] What Hermes got (`have`, the newest out) is older than this build asks for (`want`).
        case notOut(have: String, want: String)
    }

    /// [addon-progress] How an install is going, for the sheet.
    enum InstallProgress: Equatable, Sendable {
        /// Working on this bot's copy (its profile id), `index` of `total`.
        case bot(String, index: Int, total: Int)
        /// Waiting for the add-on's routes to answer.
        case loading
        /// The version Hermes installed.
        case version(String)
    }

    /// [addon-progress] The version the copies just installed must reach: the main bot's (PushPolicy.wantedVersion)
    /// when it was replaced, and every other bot's (everyBotVersion), whichever is higher.
    nonisolated static func neededVersion(main: Bool) -> String {
        guard main else { return PushPolicy.everyBotVersion }
        return PushPolicy.versionAtLeast(PushPolicy.wantedVersion, PushPolicy.everyBotVersion) ? PushPolicy.wantedVersion : PushPolicy.everyBotVersion
    }

    /// How many bots' lists are asked for at once ([load-cache]): Hermes answers them on the RPC pool that opening a
    /// chat needs too (PluginListCache).
    static let listReadWidth = 2

    /// The bots besides the main one whose own copy is missing, off or older than PushPolicy.everyBotVersion, in roster
    /// order. A bot whose list can't be read is left out (no offer on a guess).
    /// `fresh`: every list is asked for (Settings); otherwise a list kept by PluginListCache that has the add-on stands
    /// in for its bot. One without it is asked again: the main bot installs it from its terminal, which this phone
    /// doesn't see, so "not there" goes out of date in a way "there" rarely does.
    static func botsWithout(store: CapabilitiesStore?, bots: [Bot], fresh: Bool) async -> [Bot] {
        guard let store else { return [] }
        let others = bots.filter { $0.id != "default" }
        let account = store.client.account
        var lacking = Set<String>()
        let toRead = others.map(\.id).filter { id in
            guard !fresh, let entry = store.pluginLists.entry(account: account, profile: id) else { return true }
            return !PushPolicy.botHasPlugin(entry)
        }
        if !toRead.isEmpty {
            AppLog.trace("push", "setup: reading \(toRead.count) of \(others.count) bots' add-on lists, \(listReadWidth) at a time")
            // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
            await withChildTasks(of: (String, [PluginInfo]?).self) { group in
                var queue = toRead.makeIterator()
                for _ in 0..<listReadWidth {
                    guard let id = queue.next() else { break }
                    group.addTask { (id, try? await store.plugins(id)) }
                }
                while let (id, list) = await group.next() {
                    if let list, !PushPolicy.botHasPlugin(list) { lacking.insert(id) }
                    if let next = queue.next() { group.addTask { (next, try? await store.plugins(next)) } }
                }
            }
        }
        if !lacking.isEmpty { AppLog.note("push", "setup: \(lacking.count) bot(s) without their own add-on") }
        return others.filter { lacking.contains($0.id) }
    }

    /// "Gym", "Gym and Ivy", "Gym, Ivy and 3 more".
    static func names(_ bots: [Bot]) -> String { AddOnReminder.names(bots.map(\.name)) }

    /// `plugins.manage`: list (a gateway that doesn't know the method has no plugin manager), install hermes-hq-push
    /// enabled (forced over an old copy), remove the old name. Then each other bot in `others` gets its own copy the
    /// same way where it has none, or an old or switched-off one: those load when Hermes restarts, so the restart is
    /// asked for whenever one was added. [addon-progress] Then the version Hermes got is read back: older than this build
    /// asks for means the newest add-on out isn't new enough (`.notOut`), which no restart can help. Last, its routes
    /// are looked for for up to 8 s.
    /// `main`: false when only the other bots need it (the main bot's copy is current and stays as it is).
    /// `progress`: each bot as its turn comes, the version once read, the wait for the routes (the update sheet).
    static func installDirectly(store: CapabilitiesStore?, force: Bool, main: Bool = true, others: [String] = [],
                                needsIdeas: Bool = false, progress: (InstallProgress) -> Void = { _ in }) async -> DirectInstall {
        // [task-ideas] The Ideas page's update: every copy at Ideas' version, and Ideas answering before "ready".
        let botMinimum = needsIdeas ? PushPolicy.ideasVersion : PushPolicy.everyBotVersion
        guard let store else { AppLog.note("push", "setup: no store"); return .unavailable }
        let listed: [PluginInfo]
        do { listed = try await store.plugins("default") } catch {
            if let rpc = error as? RPCError, rpc.code == -32601 || rpc.message.lowercased().contains("unknown method") { return .tooOld }
            AppLog.note("push", "setup: list failed (\(type(of: error)))")
            return .unavailable
        }
        let rest = others.filter { $0 != "default" }
        let total = (main ? 1 : 0) + rest.count
        var index = 0
        // A bot whose copy was just put in: its version is the one Hermes could get.
        var probe: String?
        if main {
            index += 1
            progress(.bot("default", index: index, total: total))
            let present = listed.contains { $0.name == PushPolicy.pluginName }
            do {
                let result = try await store.plugin(.install(identifier: pluginSource, force: force || present, enable: true, ref: nil), profile: "default")
                guard result.ok || result.name != nil, !result.consentRequired else { return .unavailable }
            } catch { return .unavailable }
            if listed.contains(where: { $0.name == oldPlugin }) { _ = try? await store.plugin(.remove(name: oldPlugin), profile: "default") }
            probe = "default"
        }
        var added = 0, missed = 0
        for profile in rest {
            index += 1
            progress(.bot(profile, index: index, total: total))
            guard let theirs = try? await store.plugins(profile), !PushPolicy.botHasPlugin(theirs, minimum: botMinimum) else { continue }
            let present = theirs.contains { $0.name == PushPolicy.pluginName }
            guard let result = try? await store.plugin(.install(identifier: pluginSource, force: present, enable: true, ref: nil), profile: profile),
                  result.ok || result.name != nil, !result.consentRequired else {
                AppLog.note("push", "setup: a bot's own copy not installed")
                missed += 1
                continue
            }
            if theirs.contains(where: { $0.name == oldPlugin }) { _ = try? await store.plugin(.remove(name: oldPlugin), profile: profile) }
            added += 1
            if probe == nil { probe = profile }
        }
        if added > 0 { AppLog.note("push", "setup: \(added) bot(s) got their own copy") }
        // [addon-progress] Only other bots needed it and none of theirs went in: the main bot does the job instead
        // (this said "ready" before, and the reminder went away with nothing done).
        if !main, added == 0, missed > 0 { return .unavailable }
        if let probe, let copy = try? await store.plugins(probe).first(where: { $0.name == PushPolicy.pluginName }),
           PushPolicy.versionAtLeast(copy.version, "0") {
            progress(.version(copy.version))
            var want = neededVersion(main: main)
            if needsIdeas, !PushPolicy.versionAtLeast(want, PushPolicy.ideasVersion) { want = PushPolicy.ideasVersion }
            if !PushPolicy.versionAtLeast(copy.version, want) { return .notOut(have: copy.version, want: want) }
        }
        progress(.loading)
        for _ in 0..<4 {
            if await PushRegistrar.shared.pluginState().state == .ready, !needsIdeas || PushRegistrar.shared.taskIdeasServed {
                return added > 0 ? .needsRestart : .ready
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return .needsRestart
    }

    /// [setup-browser] Watch Browser's add-on rides along only with a first setup (an update offer adds nothing new) and
    /// never on Hermes Cloud.
    static func bringsBrowser(state: PushPolicy.PluginState, gateway: URL?) -> Bool {
        state == .missing && !CloudGatewayFlow.isCloud(gateway)
    }

    /// [setup-browser] The main bot has no browser add-on under either name (dispatch-browser, the old one, is left to
    /// Watch Browser's own request, which keeps that setup's browser toolsets). A list that can't be read: no.
    static func browserMissing(store: CapabilitiesStore?) async -> Bool {
        guard let store, let listed = try? await store.plugins("default") else { return false }
        return !listed.contains { $0.name == browserPlugin || $0.name == "dispatch-browser" }
    }

    /// [setup-browser] Watch Browser's add-on, enabled, for the main profile only: once the server restarts, it adds
    /// itself to every other bot. False when the manager refused or wants consent (Watch Browser can still ask the bot).
    static func installBrowser(store: CapabilitiesStore?) async -> Bool {
        guard let store,
              let result = try? await store.plugin(.install(identifier: BrowserSetupPrompt.source, force: false, enable: true, ref: nil), profile: "default"),
              result.ok || result.name != nil, !result.consentRequired else {
            AppLog.note("push", "setup: browser add-on not installed")
            return false
        }
        AppLog.note("push", "setup: browser add-on installed")
        return true
    }

    /// The request is queued in the bot's chat; once Hermes restarts with the plugin, alerts are turned on.
    /// [addon-progress] Looked for every 3 s for the first 4 minutes, so the sheet's Restart step ticks off as Hermes
    /// comes back (it was every 20 s), then every 20 s to the end as before; past 4 minutes the sheet says the restart
    /// is slow. `mainReplaced`: the main bot's copy was put in, so the add-on answering as current means Hermes
    /// restarted. Otherwise (other bots' copies only) it answered current before the restart too, so the restart is
    /// seen as the connection dropping and coming back. Then every bot's copy is read again, so the reminder holds
    /// only what is still missing (it was cleared on a guess).
    /// [browser-update] `push`: the notification add-on went in (false: only the browser add-on's update). `browser`:
    /// the browser add-on's update went in, so Hermes counts as restarted once its /health answers at the version this
    /// build wants, and "Check it's on" then reads that answer (installed, no drift).
    /// [manual-restart] `byHand`: the owner restarts Hermes themselves. The sheet already says so (no "slow" ending),
    /// the watch is as long as `deadline` says (a day), reading once a minute past the first 15, and running out
    /// says to restart it, not to look in the bot's chat.
    func watchForPlugin(name: String, account: String? = nil, model: AppModel? = nil, mainReplaced: Bool = true,
                        push: Bool = true, browser: Bool = false, byHand: Bool = false,
                        deadline: Date = Date().addingTimeInterval(15 * 60)) {
        watch?.cancel()
        let update = AddOnUpdate.shared, token = UUID()
        watchToken = token
        update.watch(true)
        watch = Task { @MainActor [weak self, weak model] in
            defer { if self?.watchToken == token { update.watch(false) } }
            let began = Date()
            let fastUntil = began.addingTimeInterval(4 * 60)
            var dropped = false, toldSlow = false, pushUp = !push
            while Date() < deadline, !Task.isCancelled {
                let fast = Date() < fastUntil
                // The connection is looked at every half second, so a quick restart isn't missed between reads.
                for _ in 0..<PushSetupOffer.watchTicks(since: began) {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let model, model.connection != .ready { dropped = true }
                }
                guard !Task.isCancelled else { return }
                if !fast, !toldSlow, update.phase == .working {
                    toldSlow = true
                    update.end(.slow)
                }
                if !pushUp {
                    let answer = await PushRegistrar.shared.pluginState()
                    guard answer.state == .ready, mainReplaced || dropped else { continue }
                    pushUp = true
                }
                var health: JSONValue?
                if browser {
                    guard let found = try? await model?.browser?.plugin(fresh: true), !found.legacy,
                          BrowserAddOn.restarted(found.health) else { continue }
                    health = found.health
                }
                AppLog.note("push", "setup: add-on up after the restart\(browser ? (push ? " (both)" : " (browser)") : "")")
                self?.pendingAsk = nil
                update.complete([.install, .restart])
                update.work()
                if push {
                    update.step(.verify, .active, detail: AddOnUpdate.eachBot)
                    let lacking = await Self.botsWithout(store: model?.settingsHub.capabilitiesStore, bots: model?.bots ?? [], fresh: true)
                    guard !Task.isCancelled else { return }
                    // [addon-reminder] Installed: the reminder keeps only the bots still without their own copy.
                    if let account { AddOnReminder.shared.report(account: account, state: .ready, without: lacking.map(\.name)) }
                    if !lacking.isEmpty {
                        AppLog.note("push", "setup: \(lacking.count) bot(s) still without their own copy")
                        update.end(.failed(title: AddOnUpdate.stillNeed(lacking.map(\.name)), reason: AddOnUpdate.stillNeedReason(count: lacking.count, bot: name)))
                        return
                    }
                }
                if browser, let health {
                    // [browser-update] Its /health, just read: this version or newer, installed, and nothing drifted.
                    update.step(.verify, .active, detail: AddOnUpdate.browserCheck)
                    update.installed(browser: BrowserAddOn.version(health))
                    let on = BrowserAddOn.isOn(health)
                    if let account { AddOnReminder.shared.reportBrowser(account: account, need: on ? nil : BrowserAddOn.need(health)) }
                    if !on {
                        AppLog.note("push", "setup: browser add-on up but not on")
                        update.end(.failed(title: AddOnUpdate.browserStillOff, reason: AddOnUpdate.browserStillOffReason(health, bot: name)))
                        return
                    }
                }
                update.end(.on(version: push ? update.version : update.browserVersion))
                guard push else { AppLog.note("push", "setup done, browser add-on on"); return }
                // UX study #138: up to 15 minutes later iOS's prompt would come out of nowhere; a word first, as the
                // "Know When a Bot Replies?" ask does.
                guard await Self.leadIn() else { AppLog.note("push", "setup done, permission not asked"); return }
                let granted = await AppModel.requestPermission()
                AppLog.note("push", granted ? "setup done, alerts on" : "setup done, alerts off in iOS")
                return
            }
            // UX study #138: the add-on never came up (the bot refused, the restart failed): said once, not left silent.
            guard !Task.isCancelled else { return }
            self?.pendingAsk = nil
            if pushUp, browser {
                // [browser-update] The browser add-on's update is the part that never came up.
                AppLog.note("push", "setup: browser add-on not up in time")
                let title = "Browser Add-on Isn’t Updated Yet"
                let reason = byHand ? AddOnUpdate.notRestartedReason
                    : "Hermes’s browser add-on hasn’t come up at \(BrowserAddOn.wantedVersion). Check \(name)’s chat, or try again from Settings."
                let shown = update.shownSheet != nil
                update.end(.failed(title: title, reason: reason))
                if !shown { FailureAlert.present(title: title, reason: reason, from: MainTabController.current, whole: true) }
                return
            }
            AppLog.note("push", "setup: plugin not up in time")
            let reason = byHand ? AddOnUpdate.notRestartedReason
                : "Hermes’s notification add-on hasn’t come up. Check \(name)’s chat, or try again from Settings › Notifications."
            let shown = update.shownSheet != nil
            update.end(.failed(title: "Notifications Aren’t Set Up Yet", reason: reason))
            if !shown { FailureAlert.present(title: "Notifications Aren’t Set Up Yet", reason: reason, from: MainTabController.current, whole: true) }
        }
    }

    /// Half seconds between two reads of the add-on: every 3 s for the first 4 minutes, every 20 s to 15 minutes, and
    /// once a minute after that (only a restart the owner does themselves is watched for that long).
    nonisolated static func watchTicks(since began: Date, now: Date = Date()) -> Int {
        let passed = now.timeIntervalSince(began)
        return passed < 4 * 60 ? 6 : passed < 15 * 60 ? 40 : 120
    }

    /// Before iOS's own prompt, when it would show (permission not asked yet): "Notifications Are Ready", iOS asks next.
    /// False when the person said Not Now. Asked already: nothing to say, the grant (or not) stands.
    private static func leadIn() async -> Bool {
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined else { return true }
        guard MemoController.shared.takeId == nil, let host = FailureAlert.topmost(MainTabController.current) else { return true }
        return await withCheckedContinuation { continuation in
            // [intents] Dismissed with no button tapped: Not Now (Settings › Notifications turns them on later).
            let answer = AlertAnswer(continuation, unanswered: false)
            let alert = UIAlertController(title: "Notifications Are Ready",
                                          message: "Hermes’s notification add-on is set up. \(AppIdentity.current.displayName) can now alert you when a bot replies while you’re away. \(DeviceWord.system) asks next.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in answer.answer(false) })
            let go = UIAlertAction(title: "Continue", style: .default) { _ in answer.answer(true) }
            alert.addAction(go)
            alert.preferredAction = go
            host.present(alert, animated: true)
        }
    }
}
