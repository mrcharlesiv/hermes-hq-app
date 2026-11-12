// [plugin-updates] A plugin's update shows as the add-on's does: what counts (Hermes's own flag, never the app's
// add-ons), the reminder's count and words per gateway, the version an update brings, and the update sheet's words
// and steps when it runs a plugin update.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite("Plugin updates", .serialized) struct PluginUpdatesTests {
    private static func plugin(_ name: String, version: String = "1.0.0", update: Bool = true, to: String? = "1.1.0") -> PluginInfo {
        PluginInfo(name: name, key: name, version: version, description: "", source: "catalog", enabled: true, hasDesktopHalf: false,
                   servers: [], updateAvailable: update, catalogVersion: to, catalogSha: nil, schema: [])
    }

    private static func row(_ object: [String: Any]) throws -> JSONValue {
        try JSONValue.parse(JSONSerialization.data(withJSONObject: object))
    }

    // MARK: What Hermes says

    @Test func listRowCarriesWhatTheUpdateBrings() throws {
        let catalog = try #require(PluginInfo.read(try Self.row(["name": "web-clipper", "version": "1.4.2", "source": "catalog",
                                                                  "update_available": true, "catalog_version": "1.5.0",
                                                                  "catalog_sha": "9f2c1ab04d11aa"])))
        #expect(catalog.updateAvailable && catalog.newVersion == "1.5.0")
        let pinned = try #require(PluginInfo.read(try Self.row(["name": "notes", "version": "0.8.0", "update_available": true,
                                                                 "catalog_sha": "9f2c1ab04d11aa"])))
        #expect(pinned.newVersion == "9f2c1ab", "a commit is shown short")
        let git = try #require(PluginInfo.read(try Self.row(["name": "mine", "version": "2.0", "source": "git", "update_available": true,
                                                              "update_target": "0123456789abcdef0123456789abcdef01234567"])))
        #expect(git.updateTarget != nil && git.newVersion == "0123456", "a Git install the gateway's check found behind")
        let feed = try #require(PluginInfo.read(try Self.row(["name": "fed", "version": "2.0", "update_available": true, "update_target": "2.1.0"])))
        #expect(feed.newVersion == "2.1.0", "a feed's version as it is")
        let none = try #require(PluginInfo.read(try Self.row(["name": "calm", "version": "2.0"])))
        #expect(!none.updateAvailable && none.newVersion == nil)
    }

    @Test func updateResultSaysAScanStoppedIt() throws {
        let blocked = PluginResult.read(try Self.row(["ok": false, "scan_blocked": true, "scan_verdict": "caution"]))
        #expect(blocked.scanBlocked && !blocked.ok)
        let fine = PluginResult.read(try Self.row(["ok": true, "restart_required": true, "gateway_reloaded": false]))
        #expect(!fine.scanBlocked && fine.needsRestart)
        #expect(!PluginResult.read(try Self.row(["ok": true, "restart_required": true, "gateway_reloaded": true])).needsRestart)
    }

    // MARK: The reminder

    @Test func theAppsOwnAddOnsAreNotCounted() {
        #expect(PluginUpdateReminder.counts(Self.plugin("web-clipper")))
        #expect(!PluginUpdateReminder.counts(Self.plugin("web-clipper", update: false)))
        for own in [PushPolicy.pluginName, PushSetupOffer.browserPlugin, PushSetupOffer.oldPlugin, "dispatch-browser"] {
            #expect(!PluginUpdateReminder.counts(Self.plugin(own)), "\(own) is the add-on update's")
        }
    }

    @Test func countsEachPluginOnceAcrossBots() throws {
        let defaults = try #require(UserDefaults(suiteName: "plugin-updates-\(UUID().uuidString)"))
        let reminder = PluginUpdateReminder(defaults: defaults)
        #expect(reminder.title == nil && reminder.footer == nil && !reminder.badged && reminder.hubValue == nil)
        reminder.report(account: "A", profile: "default", list: [Self.plugin("web-clipper"), Self.plugin("calm", update: false),
                                                                  Self.plugin(PushPolicy.pluginName)])
        #expect(reminder.count == 1 && reminder.badged)
        #expect(reminder.title == "Plugin Update Available")
        #expect(reminder.footer == "web-clipper has a newer version.")
        #expect(reminder.spoken == "Plugin update available" && reminder.hubValue == "1 Update")
        // Another bot's copy of the same plugin is the same update; a second plugin is a second one.
        reminder.report(account: "A", profile: "finance", list: [Self.plugin("web-clipper"), Self.plugin("field-notes")])
        #expect(reminder.count == 2 && reminder.names == ["field-notes", "web-clipper"])
        #expect(reminder.title == "2 Plugin Updates Available")
        #expect(reminder.footer == "field-notes and web-clipper have newer versions.")
        #expect(reminder.spoken == "2 plugin updates available" && reminder.hubValue == "2 Updates")
        // A bot's list read again takes the place of what was kept for it.
        reminder.report(account: "A", profile: "finance", list: [Self.plugin("web-clipper", update: false)])
        #expect(reminder.names == ["web-clipper"], "the main bot's copy still has its update")
        reminder.report(account: "A", profile: "default", list: [])
        #expect(reminder.count == 0 && reminder.title == nil)
    }

    @Test func keptPerGatewayAndForgottenOnSignOut() throws {
        let defaults = try #require(UserDefaults(suiteName: "plugin-updates-\(UUID().uuidString)"))
        let reminder = PluginUpdateReminder(defaults: defaults)
        reminder.report(account: "A", profile: "default", list: [Self.plugin("web-clipper")])
        reminder.use(account: "B")
        #expect(reminder.count == 0, "another gateway has its own")
        let later = PluginUpdateReminder(defaults: defaults)
        later.use(account: "A")
        #expect(later.count == 1, "there the moment the app opens")
        #expect(later.saved.items["default"] == [.init(name: "web-clipper", from: "1.0.0", to: "1.1.0")])
        // A bot that's gone takes its updates with it.
        later.report(account: "A", profile: "gone", list: [Self.plugin("field-notes")])
        #expect(later.count == 2)
        later.keep(account: "A", profiles: ["default"])
        #expect(later.names == ["web-clipper"])
        later.signOut(account: "A")
        #expect(later.count == 0 && defaults.data(forKey: "plugins.updateReminder.A") == nil)
        later.use(account: "")
        later.report(account: "", profile: "default", list: [Self.plugin("web-clipper")])
        #expect(later.count == 0, "signed out: nothing kept")
    }

    @Test func aListStandsForSixHours() throws {
        let defaults = try #require(UserDefaults(suiteName: "plugin-updates-\(UUID().uuidString)"))
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = PluginUpdateReminder(defaults: defaults)
        reminder.now = { clock }
        reminder.use(account: "A")
        #expect(!reminder.isFresh("default"), "never read")
        reminder.report(account: "A", profile: "default", list: [])
        #expect(reminder.isFresh("default") && !reminder.isFresh("finance"))
        clock = clock.addingTimeInterval(PluginUpdateReminder.keep - 60)
        #expect(reminder.isFresh("default"))
        clock = clock.addingTimeInterval(120)
        #expect(!reminder.isFresh("default"), "asked again after six hours")
        clock = clock.addingTimeInterval(-10 * 3600)
        #expect(!reminder.isFresh("default"), "a time ahead of the clock is stale")
    }

    // MARK: The sheet's words

    @Test func wordsNameThePluginOrTheCount() {
        let one = ["web-clipper"], three = ["web-clipper", "field-notes", "spotify"]
        #expect(PluginUpdateWords.asking(one) == "Update web-clipper?")
        #expect(PluginUpdateWords.asking(three) == "Update 3 Plugins?")
        #expect(PluginUpdateWords.headline(.on(version: nil), one) == "web-clipper Is Updated")
        #expect(PluginUpdateWords.headline(.on(version: nil), three) == "3 Plugins Are Updated")
        #expect(PluginUpdateWords.headline(.upToDate, []) == "Plugins Are Up to Date")
        #expect(PluginUpdateWords.headline(.unreachable, one) == "Couldn’t Reach Hermes", "the add-on's own words where they fit")
        #expect(PluginUpdateWords.headline(.yours, one) == "Restart Hermes to Finish")
        #expect(PluginUpdateWords.headline(.failed(title: "T", reason: "R"), one) == "T")
        #expect(PluginUpdateWords.line(.yours, one)?.hasPrefix("The update is installed. Now restart Hermes") == true)
        #expect(PluginUpdateWords.line(.yours, three)?.hasPrefix("The updates are installed.") == true)
        #expect(PluginUpdateWords.line(.slow, one) == nil && PluginUpdateWords.line(.unreachable, one) == nil)
        #expect(PluginUpdateWords.couldnt(one) == "Couldn’t Update web-clipper")
        #expect(PluginUpdateWords.couldnt(three) == "Couldn’t Update 3 Plugins")
        #expect(PluginUpdateFlow.distinct(["a", "b", "a", "c", "b"]) == ["a", "b", "c"])
    }

    @Test func restartRequestSaysWhatWasUpdatedAndNothingToInstall() {
        let one = PluginUpdateWords.restartPrompt(["web-clipper"], profiles: ["default"])
        #expect(one.contains("has just updated the plugin web-clipper through Hermes's own plugin manager"))
        #expect(!one.contains("for the profiles"), "only the main bot's: no profile list")
        #expect(one.contains(PushSetupOffer.restartStep), "the same once-only restart the add-on asks for")
        let more = PluginUpdateWords.restartPrompt(["web-clipper", "spotify"], profiles: ["default", "finance"])
        #expect(more.contains("these plugins: web-clipper and spotify (for the profiles default, finance)"))
        #expect(PluginUpdateWords.restartTitle(["a"]) == "Restart Hermes so the updated plugin loads.")
        #expect(PluginUpdateWords.restartTitle(["a", "b"]) == "Restart Hermes so the updated plugins load.")
    }

    // MARK: A run's ending ([plugin-update-run])

    private static func outcome(_ name: String, _ profile: String, _ result: PluginUpdateFlow.CopyResult) -> PluginUpdateFlow.Outcome {
        .init(item: .init(profile: profile, bot: profile.capitalized, plugin: plugin(name)), result: result)
    }

    /// The owner's run, 2026-11-11: five plugins on twelve bots, two of them only Hermes's computer can approve.
    @Test func endingSaysWhatWentInAndWhatNeedsTheComputer() {
        let refusal = "The update declares new Python dependencies (tzdata; platform_system == 'Windows'); run `hermes plugins update homeassistant` in a terminal to review them."
        #expect(PluginUpdateWords.isForComputer(refusal))
        #expect(!PluginUpdateWords.isForComputer("plugin not found"))
        let names = ["claude-sdk", "homeassistant", "honcho", "memory-wiki", "phone-harness"]
        let tally = PluginUpdateFlow.Tally([
            Self.outcome("claude-sdk", "default", .done), Self.outcome("claude-sdk", "finance", .done),
            Self.outcome("homeassistant", "default", .computer(packages: "tzdata; platform_system == 'Windows'")), Self.outcome("homeassistant", "finance", .computer(packages: "tzdata; platform_system == 'Windows'")),
            Self.outcome("honcho", "default", .doneNeedsRestart),
            Self.outcome("memory-wiki", "default", .done),
            Self.outcome("phone-harness", "default", .computer(packages: "tzdata; platform_system == 'Windows'")),
        ], plugins: names)
        #expect(tally.updated == ["claude-sdk", "honcho", "memory-wiki"])
        #expect(tally.computer == ["homeassistant", "phone-harness"])
        #expect(tally.title == "Updated 3 of 5 Plugins")
        #expect(tally.reason == "homeassistant and phone-harness add Python packages, which Hermes only lets you approve on its computer. Run hermes plugins update homeassistant there, and the same for the other.")

        // [plugin-ask-bot] The ending hands those to the main bot: what they add, in plain names, and one button.
        #expect(PluginUpdateWords.packages(in: refusal) == "tzdata; platform_system == 'Windows'")
        #expect(PluginUpdateWords.packages(in: "something else") == "")
        #expect(PluginUpdateWords.packageNames(["tzdata; platform_system == 'Windows'", "phone-harness==0.3.3, requests>=2", "tzdata"]) == ["tzdata", "phone-harness", "requests"])
        #expect(tally.packages["homeassistant"] == "tzdata; platform_system == 'Windows'")
        #expect(PluginUpdateWords.needsBot(tally.computer, packages: ["tzdata; platform_system == 'Windows'", "phone-harness==0.3.3"], bot: "Hermes")
                == "homeassistant and phone-harness add Python packages (tzdata and phone-harness), which Hermes only installs when asked on its own computer. Hermes can do that from its chat.")
        #expect(PluginUpdateWords.askBot("Hermes", count: 2) == "Ask Hermes to Update Them" && PluginUpdateWords.askBot("Otto", count: 1) == "Ask Otto to Update It")
        #expect(PluginUpdateWords.addsPackages(["a"]) == "a Adds Python Packages")
        let prompt = PluginUpdateWords.botUpdatePrompt([("homeassistant", "tzdata; platform_system == 'Windows'", ["default", "finance"]),
                                                        ("phone-harness", "phone-harness==0.3.3", ["default"])])
        #expect(prompt.contains("- homeassistant (adds: tzdata; platform_system == 'Windows'), for the profiles default, finance"))
        #expect(prompt.contains("- phone-harness (adds: phone-harness==0.3.3), for the profile default"))
        #expect(prompt.contains("I approve them") && prompt.contains("don't get around it another way"))
        #expect(PluginUpdateWords.botUpdateTitle(["homeassistant", "phone-harness"]) == "Update homeassistant and phone-harness on this Hermes.")
        #expect(AddOnUpdate.headline(.more(title: "Updated 3 of 5 Plugins", reason: "R"), setUp: false) == "Updated 3 of 5 Plugins")
        #expect(AddOnUpdate.line(.more(title: "T", reason: "R"), bot: "Hermes") == "R")

        let all = PluginUpdateFlow.Tally([Self.outcome("a", "default", .done), Self.outcome("a", "x", .done)], plugins: ["a"])
        #expect(all.updated == ["a"] && all.reason == nil, "every copy in: nothing to explain")
        let part = PluginUpdateFlow.Tally([Self.outcome("a", "default", .done), Self.outcome("a", "x", .failed("No room."))], plugins: ["a"])
        #expect(part.updated.isEmpty && part.failed == ["a"], "a plugin with a copy left behind isn't updated")
        #expect(part.title == "Couldn’t Update a" && part.reason == "No room.")
        let one = PluginUpdateFlow.Tally([Self.outcome("a", "default", .computer(packages: "tzdata; platform_system == 'Windows'"))], plugins: ["a"])
        #expect(one.reason == "a adds Python packages, which Hermes only lets you approve on its computer. Run hermes plugins update a there.")
        let no = PluginUpdateFlow.Tally([Self.outcome("a", "default", .declined), Self.outcome("b", "default", .done)], plugins: ["a", "b"])
        #expect(no.declined == ["a"] && no.reason == nil, "turned down at its question: not a failure")
        let mixed = PluginUpdateFlow.Tally([Self.outcome("a", "default", .done), Self.outcome("b", "default", .failed("No room.")),
                                            Self.outcome("c", "default", .computer(packages: "tzdata; platform_system == 'Windows'"))], plugins: ["a", "b", "c"])
        #expect(mixed.title == "Updated 1 of 3 Plugins")
        #expect(mixed.reason?.hasSuffix("b: No room.") == true)
    }

    @Test func aPluginForTheComputerStopsCountingUntilANewerVersion() throws {
        let defaults = try #require(UserDefaults(suiteName: "plugin-updates-\(UUID().uuidString)"))
        let reminder = PluginUpdateReminder(defaults: defaults)
        reminder.report(account: "A", profile: "default", list: [Self.plugin("homeassistant"), Self.plugin("honcho")])
        #expect(reminder.count == 2)
        reminder.noteNeedsComputer(account: "A", name: "homeassistant", to: "1.1.0")
        #expect(reminder.names == ["honcho"] && reminder.title == "Plugin Update Available")
        #expect(reminder.needsComputer("homeassistant", to: "1.1.0") && !reminder.needsComputer("honcho", to: "1.1.0"))
        let later = PluginUpdateReminder(defaults: defaults)
        later.use(account: "A")
        #expect(later.names == ["honcho"], "kept across launches")
        later.report(account: "A", profile: "default", list: [Self.plugin("homeassistant", to: "1.2.0")])
        #expect(later.names == ["homeassistant"], "a newer version is asked about again")
        // A reminder saved before this field existed still reads.
        let old = try JSONDecoder().decode(PluginUpdateReminder.Saved.self, from: Data(#"{"items":{},"read":{}}"#.utf8))
        #expect(old.computer == nil)
    }

    // MARK: What Hermes holds for a person's word ([plugin-consent])

    @Test func theAddOnAppliesAnUpdateTheOwnerApproved() throws {
        #expect(PluginUpdateConsent.offered(["pluginUpdates": true]))
        #expect(!PluginUpdateConsent.offered(["pluginUpdates": false]) && !PluginUpdateConsent.offered([:]) && !PluginUpdateConsent.offered(nil),
                "an older add-on, or Hermes on Windows: the main bot is asked instead")
        #expect(PluginUpdateConsent.result(["state": "running"]) == nil)
        #expect(PluginUpdateConsent.result(["state": "done", "unchanged": false]) == .doneNeedsRestart, "new code on disk: Hermes restarts to load it")
        #expect(PluginUpdateConsent.result(["state": "done", "unchanged": true]) == .done)
        #expect(PluginUpdateConsent.result(["state": "failed", "output": "Error: no room\n"]) == .failed("Error: no room"))
        #expect(PluginUpdateConsent.result(["state": "failed", "output": ""]) == .failed("Hermes didn’t apply the update."))
    }

    /// The app asks for the add-on that can (0.9.52): one that doesn't say `pluginUpdates` is offered its update; one
    /// that says false (Hermes on Windows) is current, not offered an update it can never satisfy.
    @Test func theAppAsksForTheAddOnThatAppliesUpdates() {
        #expect(PushPolicy.wantedVersion == "0.9.52" && PushPolicy.everyBotVersion == "0.9.47", "the main bot's copy serves it; no bot needs its own")
        #expect(!PushPolicy.pluginUpdatesKnown(["draftCards": true]) && !PushPolicy.pluginUpdatesKnown(nil))
        #expect(PushPolicy.pluginUpdatesKnown(["pluginUpdates": true]) && PushPolicy.pluginUpdatesKnown(["pluginUpdates": false]))
        #expect(!PushPolicy.current(["pluginUpdates": true]), "still needs every older flag")
    }

    @Test func aCautionScanCanBeForcedAndADangerousOneCannot() throws {
        let caution = PluginResult.read(try Self.row(["ok": false, "scan_blocked": true, "scan_verdict": "caution",
                                                      "scan_findings": [["description": "reads environment variables", "file": "tools.py", "line": 12],
                                                                        ["category": "network"]]]))
        #expect(caution.scanBlocked && caution.scanVerdict == "caution")
        #expect(caution.scanFindings == ["reads environment variables (tools.py)", "network"])
        #expect(PluginAction.update(name: "x", accept: true, force: true).params(profile: "default")["force"]?.bool == true)
        #expect(PluginAction.update(name: "x", accept: false).params(profile: "default")["force"] == nil, "never forced unasked")
        let tally = PluginUpdateFlow.Tally([Self.outcome("a", "default", .caution(["x"]))], plugins: ["a"])
        #expect(tally.declined == ["a"] && tally.reason == nil, "left as it was at the owner's Cancel: not a failure")
    }

    // MARK: The sheet itself

    @Test func theAddOnSheetRunsAPluginUpdate() {
        let update = AddOnUpdate.shared
        update.reset()
        defer { update.reset() }
        #expect(update.demo("plugin-asking", bot: "Hermes", model: nil))
        #expect(update.pluginRun && update.plugins == ["web-clipper"])
        #expect(update.headline == "Update web-clipper?")
        #expect(update.line == "A newer version of web-clipper is out for Hermes.")
        #expect(update.steps.map(\.title) == ["Check Hermes", "Install the update", "Restart Hermes", "Check it’s on"])
        #expect(update.changes.map(\.title) == ["web-clipper"] && update.changes.first?.from == "1.4.2" && update.changes.first?.to == "1.5.0")
        #expect(update.showsChanges && update.fillsHeight, "as tall as the add-on's, so the steps never sit under Update")
        #expect(update.hasAction && update.offersRestartChoice)

        #expect(update.demo("plugins-installing", bot: "Hermes", model: nil))
        #expect(update.plugins.count == 3 && update.busy)
        #expect(update.rowLabel == "Updating Plugins…")
        #expect(update.rowStatus == "Install the updates: field-notes for Hermes · 3 of 4")
        #expect(update.steps.last?.title == "Check they’re on")

        #expect(update.demo("plugin-on", bot: "Hermes", model: nil))
        #expect(update.headline == "web-clipper Is Updated" && update.line == "Hermes has the newest web-clipper.")
        #expect(!update.busy)

        #expect(update.demo("plugins-yours", bot: "Hermes", model: nil))
        #expect(update.headline == "Restart Hermes to Finish" && update.busy, "watched until Hermes is back")
        #expect(update.line?.hasPrefix("The updates are installed.") == true)

        #expect(update.demo("plugin-uptodate", bot: "Hermes", model: nil))
        #expect(update.headline == "Plugins Are Up to Date" && !update.showsSteps)

        // The add-on's own run is as it was.
        #expect(update.demo("asking", bot: "Hermes", model: nil))
        #expect(!update.pluginRun && update.headline == "Update the Add-on?" && update.fillsHeight)
        #expect(update.demo("installing", bot: "Hermes", model: nil))
        #expect(update.rowLabel == AddOnUpdate.rowTitle)
    }
}
