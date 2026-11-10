// [browser-update] The browser add-on (hermes-hq-browser) in the add-on update: when it counts as out of date, the
// reminder's words, the sheet's steps and endings for the browser add-on alone and for both, one install pass and one
// restart for both, and the install itself through plugins.manage (the main profile only, forced).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite("Browser add-on update", .serialized) struct BrowserAddOnUpdateTests {
    private static func health(_ object: [String: Any]) throws -> JSONValue {
        try JSONValue.parse(JSONSerialization.data(withJSONObject: object))
    }

    private static func bot(_ id: String) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false,
            pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    // MARK: When it's offered

    @Test func launchOfferOncePerBrowserVersion() {
        #expect(PushSetupOffer.shouldOffer(state: .ready, browser: true, account: "O", offered: nil, fromSettings: false))
        #expect(!PushSetupOffer.shouldOffer(state: .ready, browser: true, account: "O", offered: nil, browserOffered: "3.8.1", fromSettings: false),
                "said Not Now to 3.8.1: only the quiet reminder")
        #expect(PushSetupOffer.shouldOffer(state: .ready, browser: true, account: "O", offered: nil, browserOffered: "3.7.0", fromSettings: false),
                "a build that wants a newer one asks once more")
        #expect(PushSetupOffer.shouldOffer(state: .ready, browser: true, account: "O", offered: nil, browserOffered: "3.8.1", fromSettings: true))
        #expect(!PushSetupOffer.shouldOffer(state: .ready, browser: false, account: "O", offered: nil, fromSettings: true), "nothing to do")
        #expect(!PushSetupOffer.shouldOffer(state: .ready, browser: true, account: nil, offered: nil, fromSettings: true))
        // The notification add-on's own level is kept apart: a Not Now to it doesn't hide the browser's offer.
        #expect(PushSetupOffer.shouldOffer(state: .outdated, browser: true, account: "O", offered: PushPolicy.offerLevel, browserOffered: nil, fromSettings: false))
        #expect(!PushSetupOffer.shouldOffer(state: .outdated, browser: true, account: "O", offered: PushPolicy.offerLevel,
                                            browserOffered: BrowserAddOn.wantedVersion, fromSettings: false))
        // Push-only behaviour unchanged.
        #expect(!PushSetupOffer.shouldOffer(state: .outdated, account: "O", offered: PushPolicy.offerLevel, fromSettings: false))
        #expect(PushSetupOffer.shouldOffer(state: .missing, account: "O", offered: nil, fromSettings: false))
    }

    /// Never offered to someone who doesn't have it (the first setup brings it its own way); drift on an older add-on
    /// is "off", and the update is what turns it back on.
    @Test func readFromHealth() throws {
        func read(_ object: [String: Any], legacy: Bool = false) throws -> PushSetupOffer.BrowserRead {
            .from(BrowserService.Plugin(base: "/x", health: try Self.health(object), legacy: legacy))
        }
        #expect(try read(["installed": true, "protocol": 3, "version": "3.7.0"]) == .need(.outdated))
        #expect(try read(["installed": false, "protocol": 3, "version": "3.7.0", "drift": ["browser tools unavailable"]]) == .need(.off))
        #expect(try read(["installed": true, "protocol": 3, "version": "3.8.1"]) == .current)
        #expect(try read(["installed": false, "protocol": 3, "version": "3.8.1", "drift": ["x"]]) == .other, "current and off: no update to offer")
        #expect(try read(["installed": false, "protocol": 2]) == .other, "the old test plugin keeps Watch Browser's own page")
        #expect(try read(["installed": true, "protocol": 3, "version": "3.0.0"], legacy: true) == .absent, "dispatch-browser: not this update")
        #expect(PushSetupOffer.BrowserRead.need(.off).need == .off && PushSetupOffer.BrowserRead.current.need == nil)
    }

    // MARK: The reminder

    @Test func reminderCountsTheBrowserAddOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "browser-reminder-\(UUID().uuidString)"))
        let reminder = AddOnReminder(defaults: defaults)
        reminder.report(account: "A", state: .ready, without: [])
        #expect(!reminder.badged && reminder.title == nil)
        reminder.reportBrowser(account: "A", need: .off)
        #expect(reminder.badged && reminder.title == "Add-on Update Available" && reminder.spoken == "Add-on update available")
        #expect(reminder.footer == "Hermes’s browser add-on switched itself off after Hermes updated, so you can’t watch a bot’s browser. Add-on 3.8.1 turns it back on.")
        reminder.reportBrowser(account: "A", need: .outdated)
        #expect(reminder.footer == "Hermes’s browser add-on is out of date, so watching a bot’s browser may not work.")

        let later = AddOnReminder(defaults: defaults)
        later.use(account: "A")
        #expect(later.browser == .outdated, "kept for the next launch")
        later.use(account: "B")
        #expect(later.browser == nil, "another gateway has its own")
        later.use(account: "A")

        // Both: one row, both sentences.
        later.report(account: "A", state: .outdated, without: [])
        #expect(later.title == "Add-on Update Available")
        #expect(later.footer == "Hermes’s add-on for \(AppIdentity.current.displayName) is out of date, so some alerts and features don’t work. The browser add-on needs an update too.")
        later.reportBrowser(account: "A", need: .off)
        #expect(later.footer?.hasSuffix("The browser add-on is off until it’s updated too.") == true)
        // The notification add-on not out yet: the browser's update still counts and leads.
        later.noteNotOut(account: "A", want: PushSetupOffer.neededVersion(main: true))
        #expect(later.badged && later.title == "Add-on Update Available")
        #expect(later.footer?.hasPrefix("Hermes’s browser add-on switched itself off") == true)
        // A missing notification add-on with it (the notification add-on came out and went in first: no "not out yet").
        later.report(account: "A", state: .ready, without: [])
        #expect(later.notOut == nil && later.footer?.hasPrefix("Hermes’s browser add-on switched itself off") == true)
        later.report(account: "A", state: .missing, without: [])
        #expect(later.title == "Add-on Needed" && later.spoken == "Add-on update available")

        // Updated: the browser's part goes; push-only words are back.
        later.reportBrowser(account: "A", need: nil)
        #expect(later.browser == nil && defaults.string(forKey: "push.addOnReminder.browser.A") == nil)
        #expect(later.title == "Add-on Needed" && later.spoken == "Add-on needed")
        later.reportBrowser(account: "A", need: .outdated)
        later.signOut(account: "A")
        #expect(later.browser == nil && defaults.string(forKey: "push.addOnReminder.browser.A") == nil)
    }

    // MARK: The sheet

    @Test func browserAloneWalksTheSameSteps() throws {
        let update = AddOnUpdate()
        update.found(setUp: false, why: AddOnUpdate.why(nil, browser: .off), bot: "Hermes", both: false, browserOnly: true)
        #expect(update.addOns == .browser && !update.both)
        #expect(update.steps.map(\.title) == ["Check Hermes", "Install the browser update", "Restart Hermes", "Check it’s on"])
        #expect(AddOnUpdate.why(nil, browser: .off) == "The browser add-on in Hermes switched itself off after Hermes updated, so you can’t watch a bot’s browser. Add-on 3.8.1 turns it back on.")
        #expect(AddOnUpdate.why(nil, browser: .outdated).hasSuffix("This version of the app needs a newer one, or watching may not work."))
        #expect(AddOnUpdate.why(nil, browser: .off).count <= 160 && AddOnUpdate.why(nil, browser: .outdated).count <= 160)
        #expect(update.rowLabel == "Updating Browser Add-on…")

        update.work()
        update.step(.install, .active, detail: AddOnUpdate.installing(AddOnUpdate.browserCopy("Hermes"), 1, of: 1))
        #expect(update.rowStatus == "Install the browser update: Hermes’s browser add-on")
        update.step(.install, .done)
        update.step(.restart, .active, detail: AddOnUpdate.botRestarts("Hermes"))
        update.complete([.restart])
        update.step(.verify, .active, detail: AddOnUpdate.browserCheck)
        #expect(update.headline == "Almost Done…")
        update.installed(browser: "3.8.1")
        update.end(.on(version: update.browserVersion))
        #expect(update.headline == "Browser Add-on 3.8.1 Is On")
        #expect(update.line == "Hermes has the browser add-on \(AppIdentity.current.displayName) needs, so you can watch your bots’ browsers.")

        // Not out yet, and still off after the restart.
        #expect(AddOnUpdate.headline(.notOut(have: "3.7.0", want: "3.8.1", browser: true), setUp: false, addOns: .browser) == "Browser Add-on 3.8.1 Isn’t Out Yet")
        #expect(AddOnUpdate.line(.notOut(have: "3.7.0", want: "3.8.1", browser: true), bot: "Hermes", addOns: .browser).contains("needs browser add-on 3.8.1, but the newest one out is 3.7.0"))
        let drifted = try Self.health(["installed": false, "protocol": 3, "version": "3.8.1", "drift": ["tools moved"]])
        #expect(AddOnUpdate.browserStillOffReason(drifted, bot: "Hermes") == "Hermes restarted, but the browser add-on says: tools moved. Try again, or ask Hermes in its chat.")
        let old = try Self.health(["installed": true, "protocol": 3, "version": "3.7.0"])
        #expect(AddOnUpdate.browserStillOffReason(old, bot: "Hermes") == "Hermes restarted, but its browser add-on is still 3.7.0. Try again, or ask Hermes in its chat.")
        #expect(AddOnUpdate.browserStillOffReason(nil, bot: "Hermes").hasPrefix("Hermes restarted, but its browser add-on didn’t come up."))
    }

    @Test func bothInOneSheet() {
        let update = AddOnUpdate()
        update.found(setUp: false, why: AddOnUpdate.why(.outdated, browser: .outdated), bot: "Hermes", both: true,
                     installNote: AddOnUpdate.installPlan(bots: [], all: 12, browser: true))
        #expect(update.addOns == .both)
        // One install step and one restart for both.
        #expect(update.steps.map(\.title) == ["Check Hermes", "Install both updates", "Restart Hermes", "Check they’re on"])
        #expect(update.steps.filter { $0.id == .restart }.count == 1)
        #expect(AddOnUpdate.installPlan(bots: ["Finance", "Gym"], all: 12, browser: true) == "For Finance and Gym, and the browser add-on for all")
        #expect(AddOnUpdate.installPlan(bots: [], all: 12, browser: true) == "For all 12 bots")
        #expect(AddOnUpdate.why(.outdated, browser: .outdated).contains("both need updating"))
        #expect(AddOnUpdate.why(.bots(["Gym"]), browser: .off).hasSuffix("and the browser add-on needs an update."))
        #expect(update.rowLabel == "Updating Add-ons…")

        // "n of N" runs on into the browser add-on's copy.
        let count = PushSetupOffer.installCount(main: true, bots: ["default", "a", "b"].map(Self.bot)) + 1
        #expect(count == 4)
        #expect(PushSetupOffer.installCount(main: false, bots: ["default", "a"].map(Self.bot)) == 1)
        update.work()
        update.step(.install, .active, detail: AddOnUpdate.installing(AddOnUpdate.browserCopy("Hermes"), count, of: count))
        #expect(update.rowStatus == "Install both updates: Hermes’s browser add-on · 4 of 4")

        update.installed(version: "0.9.40")
        update.installed(browser: "3.8.1")
        update.complete([.install, .restart, .verify])
        update.end(.on(version: update.version))
        #expect(update.headline == "Both Add-ons Are On")
        #expect(update.line == "Hermes has notification add-on 0.9.40 and browser add-on 3.8.1, and every bot has its own copy.")
        #expect(AddOnUpdate.headline(.upToDate, setUp: false, addOns: .both) == "Add-ons Are Up to Date")
        #expect(AddOnUpdate.line(.upToDate, bot: "Hermes", addOns: .both).hasPrefix("Hermes and every bot have the add-ons"))

        // The browser's part didn't go in: the sheet follows the notification add-on alone.
        let narrowed = AddOnUpdate()
        narrowed.found(setUp: false, why: "", bot: "Hermes", both: true)
        narrowed.only(.push)
        #expect(narrowed.addOns == .push && narrowed.steps.map(\.title) == ["Check Hermes", "Install the update", "Restart Hermes", "Check it’s on"])
        let browserOnly = AddOnUpdate()
        browserOnly.found(setUp: false, why: "", bot: "Hermes", both: true)
        browserOnly.only(.browser)
        #expect(browserOnly.addOns == .browser && browserOnly.steps[1].title == "Install the browser update")
    }

    /// Push-only words are exactly what they were.
    @Test func pushOnlyIsUnchanged() {
        let update = AddOnUpdate()
        update.found(setUp: false, why: "", bot: "Hermes", both: false)
        #expect(update.addOns == .push && update.rowLabel == AddOnUpdate.rowTitle && update.rowLabel == "Updating Add-on…")
        #expect(update.steps.map(\.title) == ["Check Hermes", "Install the update", "Restart Hermes", "Check it’s on"])
        #expect(AddOnUpdate.headline(.on(version: "0.9.32"), setUp: false) == "Add-on 0.9.32 Is On")
        #expect(AddOnUpdate.headline(.upToDate, setUp: false) == "Add-on Is Up to Date")
        #expect(AddOnUpdate.line(.on(version: nil), bot: "Hermes") == "Hermes has the newest add-on for \(AppIdentity.current.displayName), and every bot has its own copy.")
        #expect(AddOnUpdate.installTitle(setUp: true, both: true) == "Install the add-ons")
        #expect(AddOnUpdate.verifyTitle(both: false) == "Check it’s on")
        #expect(AddOnUpdate.installPlan(bots: ["Gym"], all: 12) == "For Gym")
        #expect(PushSetupOffer.restartPrompt() == PushSetupOffer.restartPrompt(browser: false, browserUpdate: false, push: true))
        #expect(!PushSetupOffer.restartPrompt().contains("hermes-hq-browser"))
    }

    // MARK: One pass, one restart

    @Test func bothGoInWithOneRestart() {
        // Routes already answering after the install: the browser add-on's update still needs the restart, once.
        #expect(PushSetupOffer.afterInstall(.ready, browserIn: false, browserUpdated: true) == .needsRestart)
        #expect(PushSetupOffer.afterInstall(.needsRestart, browserIn: false, browserUpdated: true) == .needsRestart)
        #expect(PushSetupOffer.afterInstall(.ready, browserIn: false, browserUpdated: false) == .ready, "push alone: unchanged")
        #expect(PushSetupOffer.afterInstall(.ready, browserIn: true, browserUpdated: false) == .needsRestart, "first setup: unchanged")
        #expect(PushSetupOffer.afterInstall(.unavailable, browserIn: false, browserUpdated: true) == .unavailable)

        let both = PushSetupOffer.restartPrompt(browserUpdate: true)
        #expect(both.contains("has just installed both through Hermes's own plugin manager"))
        #expect(both.contains("hermes-hq-browser at version 3.8.1 or newer"))
        #expect(both.contains("don't update it per profile"))
        #expect(both.components(separatedBy: PushSetupOffer.restartStep).count == 2, "one restart in the request")
        #expect(both.hasSuffix("checks for the plugins itself."))
        let alone = PushSetupOffer.restartPrompt(browserUpdate: true, push: false)
        #expect(alone.hasPrefix(PushSetupOffer.browserWhoAsks))
        #expect(alone.contains("has just updated it to version 3.8.1") && alone.contains("don't update it per profile"))
        #expect(alone.components(separatedBy: PushSetupOffer.restartStep).count == 2)
        #expect(!alone.contains("hermes-hq-push,") && alone.hasSuffix("checks for the plugin itself."))
        #expect(PushSetupOffer.browserRestartTitle == "Restart Hermes so the \(AppIdentity.current.displayName) browser add-on loads.")
        #expect(BrowserSetupPrompt.update.contains("version 3.8.1 or newer") && !BrowserSetupPrompt.update.contains("3.7.0"))
    }

    // MARK: The install (plugins.manage)

    private nonisolated final class ManagerGateway: Sendable {
        let client = FakeGatewayClient()
        init(listed version: String?, install: JSONValue = .object(["ok": true, "plugin_name": "hermes-hq-browser"])) {
            client.onCall { method, params in
                guard method == "plugins.manage" else { return .object(["ok": true]) }
                switch params["action"]?.string {
                case "install": return install
                case "list":
                    guard let version else { return .object(["plugins": .array([])]) }
                    return .object(["plugins": .array([.object(["name": "hermes-hq-browser", "version": .string(version), "status": "enabled"])])])
                default: return .object(["ok": true])
                }
            }
        }

        var installs: [JSONValue] { client.calls("plugins.manage").map(\.params).filter { $0["action"]?.string == "install" } }
    }

    private func store(_ gateway: ManagerGateway) -> CapabilitiesStore {
        let store = CapabilitiesStore(client: gateway.client)
        store.pluginLists = PluginListCache(root: FileManager.default.temporaryDirectory.appending(path: "browser-update-\(UUID().uuidString)", directoryHint: .isDirectory))
        return store
    }

    @Test func updateInstallsTheMainCopyOnceForced() async {
        let gateway = ManagerGateway(listed: "3.8.1")
        #expect(await PushSetupOffer.updateBrowser(store: store(gateway)) == .installed("3.8.1"))
        let installs = gateway.installs
        #expect(installs.count == 1, "one install: the other bots' copies come from the add-on itself")
        #expect(installs.first?["profile"]?.string == "default")
        #expect(installs.first?["identifier"]?.string == BrowserSetupPrompt.source)
        #expect(installs.first?["force"]?.bool == true && installs.first?["enable"]?.bool == true)
    }

    @Test func updateFindsTheNewestOutTooOld() async {
        #expect(await PushSetupOffer.updateBrowser(store: store(ManagerGateway(listed: "3.7.0"))) == .notOut(have: "3.7.0", want: "3.8.1"))
        #expect(await PushSetupOffer.updateBrowser(store: store(ManagerGateway(listed: nil))) == .installed(nil), "no version listed: the restart's check decides")
        #expect(await PushSetupOffer.updateBrowser(store: store(ManagerGateway(listed: "3.8.1", install: .object(["ok": false, "consent_required": true])))) == .unavailable)
        #expect(await PushSetupOffer.updateBrowser(store: nil) == .unavailable)
    }
}
