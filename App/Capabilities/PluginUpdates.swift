// [plugin-updates] Owner 2026-11-11: "When plugins have an update available I want that to show just like an update
// for the HQ plugin shows." A plugin's update showed only as a small "Update available" line in Capabilities › Plugins,
// under the one bot being looked at; nobody who didn't open that list knew. Now it shows as the add-on's does:
//  - a red count on the tab that holds Settings and on More's Settings row (beside the add-on's);
//  - a "Plugin Update Available" row at the top of Settings, under the add-on's, saying which plugins;
//  - the same update sheet (AddOnUpdate): Check Hermes, Install the update (naming the plugin and the bot), Restart
//    Hermes (the main bot from its chat, or "I'll Restart Hermes Myself"), Check it's on. A plugin page's "Update to…"
//    opens that sheet for the one plugin.
// What has an update is whatever Hermes's own list says (`plugins.manage list`: a catalog install behind its pin, a Git
// install the gateway's daily check found behind). Every list the app reads reports here; a quiet read after launch
// asks the bots not read in the last six hours. The app's own add-ons (hermes-hq-push, hermes-hq-browser) are left to
// the add-on update, which knows the version a build needs.

import Observation
import SwiftUI
import UIKit

// MARK: - What has an update

@MainActor @Observable final class PluginUpdateReminder {
    static let shared = PluginUpdateReminder()

    nonisolated struct Item: Codable, Equatable, Sendable {
        var name: String
        var from: String
        var to: String?
    }

    /// One account's reminder: each bot's plugins with an update, and when that bot's list was last read.
    nonisolated struct Saved: Codable, Equatable, Sendable {
        var items: [String: [Item]] = [:]
        var read: [String: Double] = [:]
    }

    /// How long a bot's list stands before the launch check asks it again (PluginListCache's own keep).
    nonisolated static let keep: TimeInterval = 6 * 3600

    private(set) var saved = Saved()
    @ObservationIgnored private var account = ""
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var now: () -> Date = Date.init

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ account: String) -> String { "plugins.updateReminder.\(account)" }

    /// The app's own add-ons, updated by the add-on sheet.
    nonisolated static let ownAddOns: Set<String> = [PushPolicy.pluginName, PushSetupOffer.browserPlugin, "dispatch-push", "dispatch-browser"]

    /// A plugin this reminder counts: Hermes says it has an update, and it isn't one of the app's add-ons.
    nonisolated static func counts(_ plugin: PluginInfo) -> Bool { plugin.updateAvailable && !ownAddOns.contains(plugin.name) }

    /// The signed-in account's reminder; "" (signed out) has none.
    func use(account: String) {
        guard account != self.account else { return }
        self.account = account
        show(account.isEmpty ? Saved() : load(account))
    }

    private func load(_ account: String) -> Saved {
        defaults.data(forKey: key(account)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    private func store(_ value: Saved, _ account: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key(account)) }
    }

    /// One bot's list, just read: its plugins with an update take the place of what was kept for it.
    func report(account: String, profile: String, list: [PluginInfo]) {
        guard !account.isEmpty else { return }
        use(account: account)
        var next = saved
        let items = list.filter(Self.counts).map { Item(name: $0.name, from: $0.version, to: $0.newVersion) }
        next.items[profile] = items.isEmpty ? nil : items
        next.read[profile] = now().timeIntervalSince1970
        store(next, account)
        show(next)
    }

    /// The bots there are now: one that's gone takes its updates with it.
    func keep(account: String, profiles: [String]) {
        guard !account.isEmpty, account == self.account else { return }
        var next = saved
        let known = Set(profiles)
        next.items = next.items.filter { known.contains($0.key) }
        next.read = next.read.filter { known.contains($0.key) }
        guard next != saved else { return }
        store(next, account)
        show(next)
    }

    /// The bot's list was read within `keep`.
    func isFresh(_ profile: String) -> Bool {
        guard let at = saved.read[profile] else { return false }
        let age = now().timeIntervalSince1970 - at
        return age >= 0 && age < Self.keep
    }

    /// Signing out of an account forgets its reminder.
    func signOut(account: String) {
        defaults.removeObject(forKey: key(account))
        if account == self.account { show(Saved()) }
    }

    private func show(_ value: Saved) {
        guard value != saved else { return }
        let before = names
        saved = value
        // The tab's count, More's Settings row and the Mac's gear follow the add-on reminder's notice.
        if names != before { NotificationCenter.default.post(name: AddOnReminder.didChange, object: nil) }
    }

    // MARK: Words

    /// The plugins with an update, each once (a plugin three bots have is one update), A to Z.
    var names: [String] {
        Array(Set(saved.items.values.flatMap { $0.map(\.name) })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var count: Int { names.count }
    var badged: Bool { count > 0 }

    /// The row at the top of Settings.
    var title: String? {
        switch count {
        case 0: nil
        case 1: "Plugin Update Available"
        default: "\(count) Plugin Updates Available"
        }
    }

    /// Under the row: which ones.
    var footer: String? {
        let names = names
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "\(names[0]) has a newer version." : "\(AddOnReminder.names(names)) have newer versions."
    }

    /// For VoiceOver on the tab and More's Settings row.
    var spoken: String? {
        switch count {
        case 0: nil
        case 1: "Plugin update available"
        default: "\(count) plugin updates available"
        }
    }

    /// Capabilities' Plugins row.
    var hubValue: String? {
        switch count {
        case 0: nil
        case 1: "1 Update"
        default: "\(count) Updates"
        }
    }
}

// MARK: - The sheet's words for a plugin update

nonisolated enum PluginUpdateWords {
    /// "web-clipper", "3 plugins".
    static func subject(_ names: [String]) -> String { names.count == 1 ? names[0] : "\(names.count) plugins" }

    static func asking(_ names: [String]) -> String {
        names.count == 1 ? "Update \(names[0])?" : "Update \(names.count) Plugins?"
    }

    static func why(_ names: [String]) -> String {
        names.count == 1 ? "A newer version of \(names[0]) is out for Hermes." : "Newer versions of \(names.count) plugins are out for Hermes."
    }

    static func headline(_ end: AddOnUpdate.End, _ names: [String]) -> String {
        switch end {
        case .on: names.count == 1 ? "\(names[0]) Is Updated" : names.isEmpty ? "Plugins Are Updated" : "\(names.count) Plugins Are Updated"
        case .upToDate: "Plugins Are Up to Date"
        case .notOut, .unreachable, .slow, .yours, .failed: AddOnUpdate.headline(end, setUp: false)
        }
    }

    /// The line under the headline; nil where the add-on's own words fit (couldn't reach Hermes, a slow restart).
    static func line(_ end: AddOnUpdate.End, _ names: [String]) -> String? {
        switch end {
        case .on: names.count == 1 ? "Hermes has the newest \(names[0])." : "Hermes has the newest version of each."
        case .upToDate: "Every plugin on Hermes is at its newest version. Nothing to do."
        case .yours:
            "\(names.count == 1 ? "The update is" : "The updates are") installed. Now restart Hermes on its computer (hermes dashboard or hermes serve, and the gateway if it runs on its own). The app finishes once it’s back."
        case .notOut, .unreachable, .slow, .failed: nil
        }
    }

    static func couldnt(_ names: [String]) -> String {
        names.count == 1 ? "Couldn’t Update \(names[0])" : "Couldn’t Update \(names.count) Plugins"
    }

    static func stillBehind(_ names: [String]) -> String {
        names.count == 1 ? "\(names[0]) Still Needs Its Update" : "\(names.count) Plugins Still Need Their Update"
    }

    static let scanBlocked = "Hermes’s security scan stopped the update, and nothing changed. Look at what it found on Hermes’s computer (hermes plugins update)."
    static let checking = "Checking the plugins"
    static let othersWentIn = "The other updates went in."

    /// The restart, asked of the main bot. `profiles`: the bots' profile ids, when not only the main one's.
    static func restartPrompt(_ names: [String], profiles: [String]) -> String {
        let app = AppIdentity.current.displayName
        let what = names.count == 1 ? "the plugin \(names[0])" : "these plugins: \(AddOnReminder.names(names))"
        let whose = profiles.contains { $0 != "default" } ? " (for the profiles \(profiles.joined(separator: ", ")))" : ""
        return """
        This is from me, through \(app), the \(DeviceWord.name) app I'm chatting with you in; it connects to this Hermes's web dashboard. \(app) has just updated \(what)\(whose) through Hermes's own plugin manager (plugins.manage), the same update hermes plugins update makes, so nothing is left to install.

        \(PushSetupOffer.restartStep)

        When you're done, tell me in a sentence what you did. \(app) checks the \(names.count == 1 ? "plugin" : "plugins") itself.
        """
    }

    static func restartTitle(_ names: [String]) -> String {
        "Restart Hermes so the updated \(names.count == 1 ? "plugin loads" : "plugins load")."
    }
}

// MARK: - Running the update

@MainActor final class PluginUpdateFlow {
    static let shared = PluginUpdateFlow()

    /// One bot's copy of one plugin (a plugin page's Update).
    struct Target: Equatable, Sendable {
        var profile: String
        var name: String
    }

    struct Item: Equatable, Sendable {
        var profile: String
        var bot: String
        var plugin: PluginInfo
    }

    /// The restart request that wasn't sent ([manual-restart]), kept for "Ask <bot> Instead", with what was updated.
    private struct Pending {
        var bot: Bot?
        var done: [Item]
        var failure: String?
    }

    /// After an update went in (or a check found the lists changed): open plugin lists read theirs again.
    static let didChange = Notification.Name("plugins.updateFlow.didChange")

    private var running = false
    private var watch: Task<Void, Never>?
    private var watchToken: UUID?
    private var launchCheck: Task<Void, Never>?
    private var pending: Pending?
    private weak var pendingModel: AppModel?
    private var lastTarget: Target?

    /// A sign-out or switch: nothing pending for the old account (PushSetupOffer.reset closes the sheet).
    func reset() {
        launchCheck?.cancel(); launchCheck = nil
        watch?.cancel(); watch = nil; watchToken = nil
        pending = nil
        running = false
    }

    // MARK: The quiet read after launch

    /// Once the roster is there, and the launch's own reads have had their turn: the bots whose plugin list wasn't
    /// read in the last six hours are asked, one at a time (Hermes answers lists on the pool a chat's open needs).
    func afterLaunch(model: AppModel) {
        launchCheck?.cancel()
        launchCheck = Task { @MainActor [weak model] in
            for _ in 0..<30 {
                if let model, model.botsLoaded, !model.bots.isEmpty { break }
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let model, model.botsLoaded, let account = model.account?.id,
                  let store = model.settingsHub.capabilitiesStore else { return }
            let reminder = PluginUpdateReminder.shared
            reminder.use(account: account)
            let profiles = model.bots.map(\.id)
            reminder.keep(account: account, profiles: profiles)
            let stale = profiles.filter { !reminder.isFresh($0) }
            guard !stale.isEmpty else { return }
            AppLog.trace("plugins", "update check: reading \(stale.count) of \(profiles.count) bots' plugin lists")
            for profile in stale {
                guard !Task.isCancelled, model.connection == .ready else { return }
                _ = try? await store.plugins(profile)   // the store reports each list to the reminder
            }
            AppLog.note("plugins", "update check: \(reminder.count) plugin(s) with an update")
        }
    }

    // MARK: The update

    /// A tap on Settings' row (every plugin with an update, for every bot) or a plugin page's Update (`only`).
    func run(model: AppModel, only target: Target? = nil, from presenter: UIViewController?) {
        Task { @MainActor in await self.update(model: model, only: target, from: presenter) }
    }

    /// Try Again: the same update from the start, in the same sheet.
    func retry(model: AppModel, from presenter: UIViewController?) {
        run(model: model, only: lastTarget, from: presenter)
    }

    private func update(model: AppModel, only target: Target?, from presenter: UIViewController?) async {
        let update = AddOnUpdate.shared
        // A tap while an update (the add-on's too) is under way brings its sheet back.
        if update.busy || running {
            update.show(from: presenter)
            return
        }
        running = true
        defer { running = false }
        lastTarget = target
        update.beginPlugins(model: model)
        update.show(from: presenter)
        guard let store = model.settingsHub.capabilitiesStore else { update.end(.unreachable); return }
        let names = Dictionary(model.bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let profiles = target.map { [$0.profile] } ?? (model.bots.isEmpty ? ["default"] : model.bots.map(\.id))
        // The first list says whether Hermes can be asked at all.
        var lists: [String: [PluginInfo]] = [:]
        do { lists[profiles[0]] = try await store.plugins(profiles[0]) } catch {
            if CapabilitiesStore.isUnknownMethod(error) {
                update.end(.failed(title: "Update Hermes First",
                                   reason: "This Hermes is too old to update plugins from your \(DeviceWord.name). Update Hermes on \(HostWord.updateTarget), then try again."))
            } else {
                AppLog.note("plugins", "update: list not read (\(CapabilitiesStore.detail(error)))")
                update.end(.unreachable)
            }
            return
        }
        if profiles.count > 1 { update.detail(.check, "Checking each bot’s plugins") }
        lists.merge(await Self.readLists(store: store, profiles: Array(profiles.dropFirst()))) { first, _ in first }
        let items: [Item] = profiles.flatMap { profile in
            (lists[profile] ?? []).filter { PluginUpdateReminder.counts($0) && (target == nil || $0.name == target?.name) }
                .map { Item(profile: profile, bot: names[profile] ?? profile, plugin: $0) }
        }
        guard !items.isEmpty else {
            AppLog.note("plugins", "update: nothing to update")
            update.end(.upToDate)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        let plugins = Self.distinct(items.map(\.plugin.name))
        let mainBot = PushSetupOffer.setupBot(model.bots)
        let several = model.bots.count > 1
        let cards = plugins.map { name -> AddOnUpdate.Changing in
            let copies = items.filter { $0.plugin.name == name }
            let from = copies.first?.plugin.version ?? ""
            return AddOnUpdate.Changing(plugin: name, title: name, from: from.isEmpty ? nil : from, to: copies.first?.plugin.newVersion,
                                        loading: false, note: several ? "For " + AddOnReminder.names(copies.map(\.bot)) : nil)
        }
        update.foundPlugins(plugins, why: PluginUpdateWords.why(plugins), bot: mainBot?.name ?? "the main bot", installNote: nil, cards: cards)
        let go = await update.ask()
        AppLog.note("plugins", go ? "update asked: \(items.count) cop\(items.count == 1 ? "y" : "ies") of \(plugins.count) plugin(s)" : "update declined")
        guard go else { return }
        update.work()
        update.step(.install, .active)

        var done: [Item] = [], failed: [(item: Item, reason: String)] = [], declined = 0, restart = false
        for (index, item) in items.enumerated() {
            let name = item.plugin.name
            update.detail(.install, AddOnUpdate.installing(several ? "\(name) for \(item.bot)" : name, index + 1, of: items.count))
            do {
                var result = try await store.plugin(.update(name: name, accept: false), profile: item.profile)
                if result.consentRequired {
                    // The new version does more than the installed one: shown, and applied only on the owner's word.
                    guard await Self.consent(name, bot: several ? item.bot : nil, lines: result.deltaLines) else { declined += 1; continue }
                    result = try await store.plugin(.update(name: name, accept: true), profile: item.profile)
                }
                if result.scanBlocked { failed.append((item, PluginUpdateWords.scanBlocked)); continue }
                guard result.ok, !result.consentRequired else { failed.append((item, "Hermes didn’t apply the update.")); continue }
                done.append(item)
                if result.needsRestart { restart = true }
            } catch {
                AppLog.note("plugins", "update: \(name) failed (\(CapabilitiesStore.detail(error)))")
                failed.append((item, McpEntryMask.phone.text(CapabilitiesStore.detail(error))))
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        let failure = failed.first.map { _ in
            PluginUpdateWords.couldnt(Self.distinct(failed.map(\.item.plugin.name)))
        }
        guard !done.isEmpty else {
            // Nothing went in: said why, or (every one turned down at its question) nothing more to say.
            if let failure, let first = failed.first { update.end(.failed(title: failure, reason: first.reason)) } else { update.reset() }
            return
        }
        let leftover = failed.first.map { "\($0.reason) \(PluginUpdateWords.othersWentIn)" }
        AppLog.note("plugins", "update: \(done.count) installed, \(failed.count) failed, \(declined) declined, restart \(restart ? "needed" : "not needed")")
        update.step(.install, .done)
        guard restart else {
            update.step(.restart, .skipped, detail: AddOnUpdate.notNeeded)
            update.step(.verify, .active, detail: PluginUpdateWords.checking)
            await finish(done: done, failureTitle: failure, failure: leftover, bot: mainBot?.name, store: store)
            return
        }
        let waiting = Pending(bot: mainBot, done: done, failure: leftover)
        // [manual-restart] The owner restarts Hermes themselves (or there is no main bot to ask): the sheet says what's left.
        guard !update.byHand, let mainBot else {
            leaveRestart(waiting, model: model)
            return
        }
        update.step(.restart, .active, detail: AddOnUpdate.botRestarts(mainBot.name))
        guard await ask(bot: mainBot, done: done) else { return }
        watchForRestart(waiting, model: model)
    }

    /// Installed, and the restart is the owner's: the sheet ends on "Restart Hermes to Finish" and the app watches.
    private func leaveRestart(_ waiting: Pending, model: AppModel) {
        let update = AddOnUpdate.shared
        AppLog.note("plugins", "update: restart left to the owner")
        pending = waiting
        pendingModel = model
        update.step(.restart, .active, detail: AddOnUpdate.youRestart)
        update.end(.yours)
        update.show(from: nil)
        watchForRestart(waiting, model: model, byHand: true, deadline: Date().addingTimeInterval(PushSetupOffer.byHandWatch))
    }

    /// "Ask <bot> Instead": the kept request goes to the main bot's chat, and the watch starts over as the bot's.
    func askBotInstead() {
        guard let waiting = pending, let bot = waiting.bot else { return }
        pending = nil
        let update = AddOnUpdate.shared
        AppLog.note("plugins", "update: restart asked of the bot instead")
        Task { @MainActor [weak self] in
            guard let self else { return }
            update.work()
            update.step(.restart, .active, detail: AddOnUpdate.botRestarts(bot.name))
            guard await self.ask(bot: bot, done: waiting.done) else { return }
            self.watchForRestart(waiting, model: self.pendingModel)
        }
    }

    /// Queues the restart request in the main bot's chat with the sheet kept over it; a failure ends the sheet in words.
    private func ask(bot: Bot, done: [Item]) async -> Bool {
        let update = AddOnUpdate.shared
        let names = Self.distinct(done.map(\.plugin.name))
        do {
            try await MainBotRequest.queue(text: PluginUpdateWords.restartPrompt(names, profiles: Self.distinct(done.map(\.profile))),
                                           title: PluginUpdateWords.restartTitle(names), retryHint: "Try again from Settings.",
                                           keeping: update.shownSheet)
        } catch {
            AppLog.note("plugins", "update: restart request not queued")
            update.end(.failed(title: "Couldn’t Ask \(bot.name)", reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            update.show(from: nil)
            return false
        }
        update.show(from: nil)
        return true
    }

    /// Hermes restarting is seen as the connection dropping and coming back with the lists readable again (as the
    /// add-on's watch sees a restart that only other bots' copies needed). Looked for every 3 s for 4 minutes, then
    /// every 20 s to 15 minutes; past 4 minutes the sheet says the restart is slow. `byHand`: a day, as the add-on's.
    private func watchForRestart(_ waiting: Pending, model: AppModel?, byHand: Bool = false,
                                 deadline: Date = Date().addingTimeInterval(15 * 60)) {
        watch?.cancel()
        let update = AddOnUpdate.shared, token = UUID()
        watchToken = token
        update.watch(true)
        let botName = waiting.bot?.name
        watch = Task { @MainActor [weak self, weak model] in
            defer { if self?.watchToken == token { update.watch(false) } }
            let began = Date()
            let fastUntil = began.addingTimeInterval(4 * 60)
            var dropped = false, toldSlow = false
            while Date() < deadline, !Task.isCancelled {
                for _ in 0..<PushSetupOffer.watchTicks(since: began) {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let model, model.connection != .ready { dropped = true }
                }
                guard !Task.isCancelled else { return }
                if Date() >= fastUntil, !toldSlow, update.phase == .working {
                    toldSlow = true
                    update.end(.slow)
                }
                guard dropped, let model, model.connection == .ready, let store = model.settingsHub.capabilitiesStore,
                      (try? await store.plugins(waiting.done[0].profile)) != nil else { continue }
                guard !Task.isCancelled else { return }
                AppLog.note("plugins", "update: Hermes is back after the restart")
                self?.pending = nil
                update.complete([.install, .restart])
                update.work()
                update.step(.verify, .active, detail: PluginUpdateWords.checking)
                await self?.finish(done: waiting.done, failureTitle: waiting.failure.map { _ in "Some Updates Didn’t Go In" },
                                   failure: waiting.failure, bot: botName, store: store)
                return
            }
            guard !Task.isCancelled else { return }
            self?.pending = nil
            AppLog.note("plugins", "update: no restart seen in time")
            let title = "Hermes Hasn’t Restarted Yet"
            let reason = byHand || botName == nil
                ? "The update is installed, and loads once Hermes restarts. Restart it on its computer."
                : "The update is installed, and loads once Hermes restarts. Check \(botName ?? "")’s chat, or restart it on its computer."
            let shown = update.shownSheet != nil
            update.end(.failed(title: title, reason: reason))
            if !shown { FailureAlert.present(title: title, reason: reason, from: MainTabController.current, whole: true) }
        }
    }

    /// "Check it's on": each updated copy's list is read again. A plugin still behind (or gone) is said; otherwise
    /// the sheet ends on "<plugin> Is Updated" (or on what didn't go in, when some did and some didn't).
    private func finish(done: [Item], failureTitle: String?, failure: String?, bot: String?, store: CapabilitiesStore) async {
        let update = AddOnUpdate.shared
        let lists = await Self.readLists(store: store, profiles: Self.distinct(done.map(\.profile)))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        let behind = done.filter { item in
            guard let list = lists[item.profile] else { return false }   // not read: no claim on a guess
            return list.first { $0.name == item.plugin.name }?.updateAvailable ?? true
        }
        if !behind.isEmpty {
            AppLog.note("plugins", "update: \(behind.count) cop\(behind.count == 1 ? "y" : "ies") still behind")
            let ask = bot.map { ", or ask \($0) in its chat" } ?? ""
            update.end(.failed(title: PluginUpdateWords.stillBehind(Self.distinct(behind.map(\.plugin.name))),
                               reason: "Hermes still lists an update for \(behind.count == 1 ? "it" : "them"). Try again\(ask)."))
            return
        }
        if let failure {
            update.step(.verify, .done)
            update.end(.failed(title: failureTitle ?? "Some Updates Didn’t Go In", reason: failure))
            return
        }
        update.step(.verify, .done)
        update.end(.on(version: nil))
    }

    // MARK: Pieces

    /// The bots' lists, two at a time (PushSetupOffer.listReadWidth); a list that can't be read is left out.
    static func readLists(store: CapabilitiesStore, profiles: [String]) async -> [String: [PluginInfo]] {
        guard !profiles.isEmpty else { return [:] }
        var out: [String: [PluginInfo]] = [:]
        await withChildTasks(of: (String, [PluginInfo]?).self) { group in
            var queue = profiles.makeIterator()
            for _ in 0..<PushSetupOffer.listReadWidth {
                guard let id = queue.next() else { break }
                group.addTask { (id, try? await store.plugins(id)) }
            }
            while let (id, list) = await group.next() {
                if let list { out[id] = list }
                if let next = queue.next() { group.addTask { (next, try? await store.plugins(next)) } }
            }
        }
        return out
    }

    /// Each once, in the order first seen.
    nonisolated static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// The new version adds things the installed one doesn't have (tools, hooks): shown over the sheet, and applied
    /// only on "Apply Update". False for Cancel, or an alert that went away unanswered.
    private static func consent(_ name: String, bot: String?, lines: [String]) async -> Bool {
        guard let host = AddOnUpdate.shared.shownSheet ?? FailureAlert.topmost(MainTabController.current) else { return false }
        var shown = Array(lines.prefix(12))
        if lines.count > 12 { shown.append("and \(lines.count - 12) more") }
        return await withCheckedContinuation { continuation in
            let answer = AlertAnswer(continuation, unanswered: false)
            let alert = UIAlertController(title: "\(name) asks for more",
                                          message: "The new version\(bot.map { " for \($0)" } ?? "") adds things the installed one does not have. Apply it only if you trust them:\n"
                                            + shown.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer.answer(false) })
            alert.addAction(UIAlertAction(title: "Apply Update", style: .default) { _ in answer.answer(true) })
            host.present(alert, animated: true)
        }
    }
}
