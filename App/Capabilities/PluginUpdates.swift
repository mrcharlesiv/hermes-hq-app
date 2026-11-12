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
        /// [plugin-update-run] Plugin → the version Hermes would only take on its computer (it adds Python packages):
        /// not counted, since there is nothing to tap here for it, until a newer version is out.
        var computer: [String: String]? = nil
    }

    /// An update found `name`'s new version (`to`) is one only Hermes's computer can approve.
    func noteNeedsComputer(account: String, name: String, to: String?) {
        guard !account.isEmpty else { return }
        use(account: account)
        var next = saved
        var all = next.computer ?? [:]
        all[name] = to ?? ""
        next.computer = all
        store(next, account)
        show(next)
    }

    func needsComputer(_ name: String, to: String?) -> Bool {
        guard let held = saved.computer?[name] else { return false }
        return held == (to ?? "")
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
        #if DEBUG
        // UI tests (`-HQDebugResetAccounts YES`) start with nothing kept from the run before.
        if !account.isEmpty, defaults.bool(forKey: "HQDebugResetAccounts") { defaults.removeObject(forKey: key(account)) }
        #endif
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
        Array(Set(saved.items.values.flatMap { $0.filter { !needsComputer($0.name, to: $0.to) }.map(\.name) })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        case .notOut, .unreachable, .slow, .yours, .failed, .more: AddOnUpdate.headline(end, setUp: false)
        }
    }

    /// The line under the headline; nil where the add-on's own words fit (couldn't reach Hermes, a slow restart).
    static func line(_ end: AddOnUpdate.End, _ names: [String]) -> String? {
        switch end {
        case .on: names.count == 1 ? "Hermes has the newest \(names[0])." : "Hermes has the newest version of each."
        case .upToDate: "Every plugin on Hermes is at its newest version. Nothing to do."
        case .yours:
            "\(names.count == 1 ? "The update is" : "The updates are") installed. Now restart Hermes on its computer (hermes dashboard or hermes serve, and the gateway if it runs on its own). The app finishes once it’s back."
        case .notOut, .unreachable, .slow, .failed, .more: nil
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
    /// [plugin-update-run] The install step's line while the gateway is out of reach (the app was in the background).
    static let paused = "Paused. Carries on when Hermes is back in reach."
    static let awayTooLong = "Hermes stayed out of reach. Try again."

    /// Hermes's refusal for an update that adds Python packages: only `hermes plugins update` on its computer shows
    /// them for review, so nothing the app sends can apply it.
    static func isForComputer(_ message: String) -> Bool { message.contains("declares new Python dependencies") }

    /// The packages Hermes's refusal names: "… new Python dependencies (tzdata; platform_system == 'Windows'); run …".
    static func packages(in message: String) -> String {
        guard let open = message.range(of: "dependencies ("), let close = message.range(of: "); run", range: open.upperBound..<message.endIndex) else { return "" }
        return String(message[open.upperBound..<close.lowerBound])
    }

    /// Their names alone, for the sheet: "tzdata", "phone-harness" (no version pins or platform markers).
    static func packageNames(_ specs: [String]) -> [String] {
        var seen = Set<String>()
        return specs.flatMap { $0.components(separatedBy: ", ") }.compactMap { spec in
            let name = String(spec.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
    }

    /// [plugin-ask-bot] Owner 2026-11-11, on "Run hermes plugins update homeassistant there" with a Try Again button:
    /// "Fix this." The ending hands the rest to the main bot instead: what the plugins add, and one button.
    static func needsBot(_ names: [String], packages: [String], bot: String) -> String {
        let one = names.count == 1
        let added = packageNames(packages)
        let what = added.isEmpty ? "Python packages" : "Python packages (\(AddOnReminder.names(added)))"
        return "\(AddOnReminder.names(names)) \(one ? "adds" : "add") \(what), which Hermes only installs when asked on its own computer. \(bot) can do that from its chat."
    }

    static func askBot(_ bot: String, count: Int) -> String { "Ask \(bot) to Update \(count == 1 ? "It" : "Them")" }

    static func addsPackages(_ names: [String]) -> String {
        names.count == 1 ? "\(names[0]) Adds Python Packages" : "\(names.count) Plugins Add Python Packages"
    }

    /// The request in the main bot's chat. `rows`: each plugin, what it adds, and the profiles that have it.
    static func botUpdatePrompt(_ rows: [(name: String, packages: String, profiles: [String])]) -> String {
        let app = AppIdentity.current.displayName
        let list = rows.map { row in
            "- \(row.name)\(row.packages.isEmpty ? "" : " (adds: \(row.packages))"), for \(row.profiles.count == 1 ? "the profile" : "the profiles") \(row.profiles.joined(separator: ", "))"
        }.joined(separator: "\n")
        return """
        This is from me, through \(app), the \(DeviceWord.name) app I'm chatting with you in; it connects to this Hermes's web dashboard. I asked it to update my Hermes plugins. Hermes refused \(rows.count == 1 ? "this one" : "these") from the app, because the new \(rows.count == 1 ? "version adds" : "versions add") Python packages, which it only installs when asked in a terminal:

        \(list)

        I've seen those packages in \(app) and I approve them. Please update \(rows.count == 1 ? "it" : "each one") with your terminal tools: hermes plugins update <name> for the default profile, hermes -p <profile> plugins update <name> for another. If the command stops to ask about the Python packages, answer yes for me (for example: yes | hermes plugins update <name>). If it still refuses without a terminal, tell me what it said and stop; don't get around it another way. Don't restart anything unless the command says a restart is needed, and then tell me first.

        When you're done, tell me in a sentence or two which ones updated.
        """
    }

    static func botUpdateTitle(_ names: [String]) -> String {
        "Update \(AddOnReminder.names(names)) on this Hermes."
    }

    static func needsComputer(_ names: [String]) -> String {
        let one = names.count == 1
        return "\(AddOnReminder.names(names)) \(one ? "adds" : "add") Python packages, which Hermes only lets you approve on its computer. Run hermes plugins update \(names[0]) there\(one ? "" : ", and the same for the \(names.count == 2 ? "other" : "others")")."
    }
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
        var failureTitle: String? = nil
        /// [plugin-ask-bot] The ending hands plugins to the main bot (`HandOff`), not "failed".
        var handsOn = false
    }

    /// [plugin-ask-bot] The plugins the main bot is asked to update from its chat, kept for the ending's button.
    struct HandOff {
        var bot: Bot
        var rows: [(name: String, packages: String, profiles: [String])]
    }
    private var handOff: HandOff?

    var handOffButton: String {
        PluginUpdateWords.askBot(handOff?.bot.name ?? "Hermes", count: handOff?.rows.count ?? 2)
    }

    /// The ending's button: the sheet closes, the main bot's chat opens with the request (sent at once when it's free).
    func askBotToFinish() {
        guard let handOff else { return }
        self.handOff = nil
        let update = AddOnUpdate.shared
        let names = handOff.rows.map(\.name)
        AppLog.note("plugins", "update: \(names.count) plugin(s) asked of the bot")
        Task { @MainActor in
            update.reset()
            do {
                try await MainBotRequest.queue(text: PluginUpdateWords.botUpdatePrompt(handOff.rows), title: PluginUpdateWords.botUpdateTitle(names),
                                               retryHint: "Try again from Settings.")
            } catch {
                AppLog.note("plugins", "update: bot request not queued")
                FailureAlert.present(title: "Couldn’t Ask \(handOff.bot.name)", reason: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                                     from: MainTabController.current)
            }
        }
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
            (lists[profile] ?? []).filter {
                guard PluginUpdateReminder.counts($0) else { return false }
                // A plugin's own page tries it whatever was found before; an update of them all leaves out the ones
                // Hermes sent to its computer (until a newer version is out).
                if let target { return $0.name == target.name }
                return !PluginUpdateReminder.shared.needsComputer($0.name, to: $0.newVersion)
            }
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

        // [plugin-update-run] The bots' copies go in three bots at a time, the app waits out a trip to the background,
        // and a new version that asks for more is asked about once for the plugin, not once for each bot.
        var outcomes = await install(items, accept: false, store: store, model: model, several: several)
        let asking = outcomes.compactMap { outcome -> (Item, [String])? in
            if case .consent(let lines) = outcome.result { return (outcome.item, lines) } else { return nil }
        }
        var accepted = Set<String>()
        for name in Self.distinct(asking.map(\.0.plugin.name)) {
            let lines = asking.first { $0.0.plugin.name == name }?.1 ?? []
            if await Self.consent(name, bot: nil, lines: lines) { accepted.insert(name) }
        }
        let again = asking.map(\.0).filter { accepted.contains($0.plugin.name) }
        if !again.isEmpty {
            let second = await install(again, accept: true, store: store, model: model, several: several)
            outcomes = outcomes.filter { !again.contains($0.item) } + second
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        let done = outcomes.filter { $0.result == .done || $0.result == .doneNeedsRestart }.map(\.item)
        let restart = outcomes.contains { $0.result == .doneNeedsRestart }
        let tally = Tally(outcomes, plugins: plugins)
        // What only Hermes's computer can approve stops counting: there is nothing to tap here for it.
        if let account = model.account?.id {
            for name in tally.computer {
                PluginUpdateReminder.shared.noteNeedsComputer(account: account, name: name, to: items.first { $0.plugin.name == name }?.plugin.newVersion)
            }
        }
        AppLog.note("plugins", "update: \(done.count) of \(items.count) copies installed; \(tally.updated.count) of \(plugins.count) plugin(s) whole, \(tally.computer.count) for Hermes's computer, \(tally.failed.count) failed, \(tally.declined.count) declined, restart \(restart ? "needed" : "not needed")")
        // [plugin-ask-bot] What only Hermes's computer can approve is the main bot's to do, on the owner's tap.
        handOff = nil
        var handsOn = false
        var title = tally.title, reason = tally.reason
        if !tally.computer.isEmpty, let mainBot {
            handsOn = true
            handOff = HandOff(bot: mainBot, rows: tally.computer.map { name in
                (name, tally.packages[name] ?? "", Self.distinct(items.filter { $0.plugin.name == name }.map(\.profile)))
            })
            if tally.updated.isEmpty { title = PluginUpdateWords.addsPackages(tally.computer) }
            var parts = [PluginUpdateWords.needsBot(tally.computer, packages: tally.computer.compactMap { tally.packages[$0] }, bot: mainBot.name)]
            if let first = tally.firstFailure { parts.append("\(AddOnReminder.names(tally.failed)): \(first)") }
            reason = parts.joined(separator: " ")
        }
        guard !done.isEmpty else {
            // Nothing went in: said why, or (every one turned down at its question) nothing more to say.
            if let reason { update.end(handsOn ? .more(title: title, reason: reason) : .failed(title: title, reason: reason)) } else { update.reset() }
            return
        }
        let failure: String? = reason == nil ? nil : title
        let leftover = reason
        update.step(.install, .done)
        guard restart else {
            update.step(.restart, .skipped, detail: AddOnUpdate.notNeeded)
            update.step(.verify, .active, detail: PluginUpdateWords.checking)
            await finish(done: done, failureTitle: failure, failure: leftover, handsOn: handsOn, bot: mainBot?.name, store: store)
            return
        }
        let waiting = Pending(bot: mainBot, done: done, failure: leftover, failureTitle: failure, handsOn: handsOn)
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
                await self?.finish(done: waiting.done, failureTitle: waiting.failureTitle,
                                   failure: waiting.failure, handsOn: waiting.handsOn, bot: botName, store: store)
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
    private func finish(done: [Item], failureTitle: String?, failure: String?, handsOn: Bool = false, bot: String?, store: CapabilitiesStore) async {
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
            let title = failureTitle ?? "Some Updates Didn’t Go In"
            update.end(handsOn ? .more(title: title, reason: failure) : .failed(title: title, reason: failure))
            return
        }
        update.step(.verify, .done)
        update.end(.on(version: nil))
    }

    // MARK: Installing ([plugin-update-run])

    /// How one copy's update went.
    enum CopyResult: Equatable, Sendable {
        case done, doneNeedsRestart
        /// The new version does more than the installed one (its lines): applied only on the owner's word.
        case consent([String])
        /// The owner said no to that question.
        case declined
        /// Hermes only lets this update be approved on its computer (it adds Python packages: `packages`, as Hermes
        /// names them).
        case computer(packages: String)
        case failed(String)
    }

    struct Outcome: Equatable, Sendable {
        var item: Item
        var result: CopyResult
    }

    /// What a whole run came to, by plugin: a plugin is updated when every copy of it went in.
    struct Tally: Equatable {
        var total: Int
        var updated: [String] = []
        var computer: [String] = []
        var declined: [String] = []
        var failed: [String] = []
        var firstFailure: String?
        /// Plugin → the Python packages its update adds, as Hermes named them.
        var packages: [String: String] = [:]

        init(_ outcomes: [Outcome], plugins: [String]) {
            total = plugins.count
            for name in plugins {
                let results = outcomes.filter { $0.item.plugin.name == name }.map(\.result)
                if let added = results.compactMap({ result -> String? in if case .computer(let packages) = result { packages } else { nil } }).first {
                    computer.append(name)
                    packages[name] = added
                }
                else if let reason = results.compactMap({ result -> String? in if case .failed(let reason) = result { reason } else { nil } }).first {
                    failed.append(name)
                    if firstFailure == nil { firstFailure = reason }
                }
                else if results.contains(where: { if case .consent = $0 { true } else { $0 == .declined } }) { declined.append(name) }
                else if !results.isEmpty { updated.append(name) }
            }
        }

        /// "Updated 3 of 5 Plugins", or "Couldn't Update …" when none went in whole.
        var title: String {
            updated.isEmpty ? PluginUpdateWords.couldnt(computer + failed + declined) : "Updated \(updated.count) of \(total) Plugins"
        }

        /// Why the rest didn't; nil when nothing failed (all updated, or only turned down at the question).
        var reason: String? {
            var parts: [String] = []
            if !computer.isEmpty { parts.append(PluginUpdateWords.needsComputer(computer)) }
            if let firstFailure {
                parts.append(failed.count == 1 && computer.isEmpty && updated.isEmpty ? firstFailure : "\(AddOnReminder.names(failed)): \(firstFailure)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// How many bots' copies go in at once (a bot's own run one after another: Hermes locks each plugin's folder).
    static let installWidth = 3
    private var installed = 0
    private var installTotal = 0
    /// Plugins Hermes sent to its computer for one bot: the other bots' copies get the same answer without asking.
    private var computerOnly: [String: String] = [:]

    private func install(_ items: [Item], accept: Bool, store: CapabilitiesStore, model: AppModel, several: Bool) async -> [Outcome] {
        installed = 0
        installTotal = items.count
        computerOnly = [:]
        if let first = items.first {
            AddOnUpdate.shared.detail(.install, AddOnUpdate.installing(several ? "\(first.plugin.name) for \(first.bot)" : first.plugin.name, 1, of: items.count))
        }
        var byBot: [[Item]] = []
        for profile in Self.distinct(items.map(\.profile)) { byBot.append(items.filter { $0.profile == profile }) }
        var out: [Outcome] = []
        await withChildTasks(of: [Outcome].self) { group in
            var queue = byBot.makeIterator()
            for _ in 0..<Self.installWidth {
                guard let next = queue.next() else { break }
                group.addTask { await self.install(bot: next, accept: accept, store: store, model: model, several: several) }
            }
            while let results = await group.next() {
                out += results
                if let next = queue.next() { group.addTask { await self.install(bot: next, accept: accept, store: store, model: model, several: several) } }
            }
        }
        // In the order asked, whatever order the bots finished in.
        return items.compactMap { item in out.first { $0.item == item } }
    }

    private func install(bot items: [Item], accept: Bool, store: CapabilitiesStore, model: AppModel, several: Bool) async -> [Outcome] {
        var out: [Outcome] = []
        for item in items {
            let name = item.plugin.name
            let result: CopyResult
            if let packages = computerOnly[name] { result = .computer(packages: packages) }
            else { result = await one(item, accept: accept, store: store, model: model) }
            if case .computer(let packages) = result { computerOnly[name] = packages }
            installed += 1
            if installed < installTotal {
                AddOnUpdate.shared.detail(.install, AddOnUpdate.installing(several ? "\(name) for \(item.bot)" : name, installed + 1, of: installTotal))
            }
            out.append(Outcome(item: item, result: result))
        }
        return out
    }

    /// One copy's update. A call the connection dropped under (the app went to the background, Hermes blinked) is
    /// made again once the gateway is back: the update is the same asked twice, and answers "unchanged" if it had
    /// gone in. Only Hermes's own refusal is a failure.
    private func one(_ item: Item, accept: Bool, store: CapabilitiesStore, model: AppModel) async -> CopyResult {
        let name = item.plugin.name
        var lastError = ""
        for attempt in 0..<4 {
            guard await Self.linkReady(model) else { return .failed(PluginUpdateWords.awayTooLong) }
            do {
                let result = try await store.plugin(.update(name: name, accept: accept), profile: item.profile)
                if result.consentRequired { return .consent(result.deltaLines) }
                if result.scanBlocked { return .failed(PluginUpdateWords.scanBlocked) }
                guard result.ok else { return .failed("Hermes didn’t apply the update.") }
                return result.needsRestart ? .doneNeedsRestart : .done
            } catch let refusal as RPCError {
                AppLog.note("plugins", "update: \(name) refused (\(refusal.message))")
                if PluginUpdateWords.isForComputer(refusal.message) { return .computer(packages: PluginUpdateWords.packages(in: refusal.message)) }
                return .failed(McpEntryMask.phone.text(CapabilitiesStore.detail(refusal)))
            } catch {
                lastError = McpEntryMask.phone.text(CapabilitiesStore.detail(error))
                AppLog.note("plugins", "update: \(name) not answered (\(lastError)), try \(attempt + 1)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return .failed(lastError)
    }

    /// Waits for the gateway's connection (up to ten minutes awake; time in the background doesn't count, the app
    /// isn't running then), saying so in the sheet. False when it never came back.
    private static func linkReady(_ model: AppModel) async -> Bool {
        guard model.connection != .ready else { return true }
        let update = AddOnUpdate.shared
        let before = update.steps.first { $0.id == .install }?.detail
        update.detail(.install, PluginUpdateWords.paused)
        for _ in 0..<1200 where model.connection != .ready { try? await Task.sleep(for: .milliseconds(500)) }
        guard model.connection == .ready else { return false }
        update.detail(.install, before)
        return true
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
