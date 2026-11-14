// Notifications (build 6): the extension's work on the shared seal vectors (simctl push never runs an extension, so this
// is where it is tested), payload parsing and routing, the badge math, push registration against a stand-in plugin, the
// app identity switch and reading the web app's Keychain sign-in.

import Foundation
import Security
import Testing
import UIKit
import UserNotifications
@testable import HermesHQNative

private enum Vectors {
    static let doc: [String: Any] = {
        let data = (try? Data(contentsOf: PushFixtures.url("seal-vectors.json"))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }()
    static var key: Data { Data(base64Encoded: doc["key"] as? String ?? "") ?? Data() }
    static func outer(_ name: String) -> [String: Any] {
        ((doc["cases"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["outer"] as? [String: Any]) ?? [:]
    }
    static func content(_ name: String) -> UNNotificationContent {
        let outer = outer(name)
        let content = UNMutableNotificationContent()
        let alert = (outer["aps"] as? [String: Any])?["alert"] as? [String: Any]
        content.title = alert?["title"] as? String ?? ""
        content.body = alert?["body"] as? String ?? ""
        content.userInfo = outer
        return content
    }
}

private final class Recorder: @unchecked Sendable {
    var outcomes: [String] = []
}

private func environment(keys: [Data], face: Data? = nil, locked: Bool = false, recorder: Recorder) -> NotificationOpener.Environment {
    NotificationOpener.Environment(keys: { keys }, face: { _, _ in face }, locked: { locked }, record: { recorder.outcomes.append($0) })
}

@Suite struct NotificationExtensionTests {
    @Test func opensASealedApprovalWithItsWordsThreadCategoryAndFields() {
        let recorder = Recorder()
        let shown = NotificationOpener.process(Vectors.content("approval"), environment: environment(keys: [PushSeal.makeKey(), Vectors.key], recorder: recorder))
        #expect(shown.title == "Sam")
        #expect(shown.body == "Wants to run: npm run deploy")
        #expect(shown.threadIdentifier == "20261003_101500_ab12cd")
        #expect(shown.categoryIdentifier == NotificationHub.approvalCategory)
        #expect(shown.relevanceScore == 1.0)
        #expect(shown.userInfo["seal"] == nil)
        let remote = shown.userInfo["dispatch"] as? [String: Any]
        #expect(remote?["request"] as? String == "req_42" && remote?["sessionKey"] as? String == "agent:main:desktop:dm:1")
        #expect(NotificationRules.target(shown.userInfo)?.session == "20261003_101500_ab12cd")
        #expect(NotificationRules.target(shown.userInfo)?.profile == "sam")
        #expect(recorder.outcomes == ["noFace"], "opened, but no face saved for Sam")
    }

    @Test func aReplyOpensWithoutActionsAndCountsAsOpenedWithAFace() {
        let recorder = Recorder()
        let face = NotificationHub.roundPNG(UIImageForTests.dot) ?? Data([1])
        let shown = NotificationOpener.process(Vectors.content("turnDone"), environment: environment(keys: [Vectors.key], face: face, recorder: recorder))
        #expect(shown.body.hasPrefix("The launch plan is ready.") && shown.categoryIdentifier.isEmpty && shown.relevanceScore == 0.6)
        #expect(recorder.outcomes == ["opened"])
    }

    @Test func showPreviewsOffSaysOnlyWho() {
        let recorder = Recorder()
        let shown = NotificationOpener.process(Vectors.content("who-only"), environment: environment(keys: [Vectors.key], recorder: recorder))
        #expect(shown.title.isEmpty && shown.body == "New reply from Sam")
    }

    @Test func aSealWithNoKeyHereStaysNewNotificationWithNoApprove() {
        let recorder = Recorder()
        let content = Vectors.content("approval").mutableCopy() as! UNMutableNotificationContent
        content.categoryIdentifier = NotificationHub.approvalCategory   // even if a plugin put one outside
        let shown = NotificationOpener.process(content, environment: environment(keys: [PushSeal.makeKey()], recorder: recorder))
        #expect(shown.title == "Hermes HQ" && shown.body == "New notification" && shown.categoryIdentifier.isEmpty)
        #expect(recorder.outcomes == ["noKey"])
        #expect(!PushPolicy.mayAnswer("approve", delivered: shown.userInfo) && PushPolicy.mayAnswer("deny", delivered: shown.userInfo))
    }

    @Test func lockedKeychainAndTamperingAreCounted() {
        let recorder = Recorder()
        _ = NotificationOpener.process(Vectors.content("turnDone"), environment: environment(keys: [], locked: true, recorder: recorder))
        var outer = Vectors.outer("turnDone")
        var seal = outer["seal"] as! [String: Any]
        var box = Data(base64Encoded: seal["box"] as! String)!
        box[5] ^= 0xff
        seal["box"] = box.base64EncodedString()
        outer["seal"] = seal
        let content = UNMutableNotificationContent()
        content.userInfo = outer
        _ = NotificationOpener.process(content, environment: environment(keys: [Vectors.key], recorder: recorder))
        #expect(recorder.outcomes == ["locked", "unreadable"])
    }

    @Test func anOldDispatchPlaceholderIsRetitledAndPlainPushesPassThrough() {
        let recorder = Recorder()
        let old = Vectors.content("turnDone").mutableCopy() as! UNMutableNotificationContent
        old.title = "Dispatch"
        #expect(NotificationOpener.process(old, environment: environment(keys: [], recorder: recorder)).title == "Hermes HQ")
        let plain = UNMutableNotificationContent()
        plain.title = "Plain"
        #expect(NotificationOpener.process(plain, environment: environment(keys: [], recorder: recorder)).title == "Plain")
        #expect(NotificationOpener.expired(Vectors.content("approval")) { recorder.outcomes.append($0) }.categoryIdentifier.isEmpty)
        #expect(recorder.outcomes == ["noKey", "plain", "expired"])
    }

    @Test func diagnosticsCountsAddUpAndKeepTheLatestTime() {
        let a = PushAlertDiagnostics.adding("opened", at: 2_000_000_000_000, to: [:])
        let b = PushAlertDiagnostics.adding("opened", at: 2_000_000_000_500, to: a)
        #expect(b["opened"] == 2 && b["openedLastAt"] == 2_000_000_000_500)
        #expect(PushAlertDiagnostics.merged(["opened": 1, "openedLastAt": 2_000_000_000_000], ["opened": 2, "openedLastAt": 2_000_000_000_900])
                == ["opened": 3, "openedLastAt": 2_000_000_000_900])
    }
}

enum UIImageForTests {
    static var dot: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}

@Suite struct NotificationRoutingTests {
    @Test func linksOpenAChatOrFillTheSignInForm() {
        #expect(NotificationRules.link(URL(string: "hermes://session/20261003_101500_ab12cd")!, scheme: "hermes") == .session("20261003_101500_ab12cd"))
        #expect(NotificationRules.link(URL(string: "hermes://session/../etc")!, scheme: "hermes") == nil)
        #expect(NotificationRules.link(URL(string: "hermes://session/abc?x=1")!, scheme: "hermes") == nil)
        #expect(NotificationRules.link(URL(string: "hermes://connect?url=https://Mac.tail1234.ts.net:9119/")!, scheme: "hermes")
                == .connect("https://mac.tail1234.ts.net:9119"))
        #expect(NotificationRules.link(URL(string: "hermes://connect?url=http://mac.local")!, scheme: "hermes") == nil, "https only")
        #expect(NotificationRules.link(URL(string: "hermes://connect?url=https://user:pw@mac.example.com")!, scheme: "hermes") == nil)
        #expect(NotificationRules.link(URL(string: "hermes://connect?url=https://localhost")!, scheme: "hermes") == nil, "a host with a dot")
        #expect(NotificationRules.link(URL(string: "hermeshq-native://session/abc")!, scheme: "hermeshq-native") == .session("abc"))
        #expect(NotificationRules.link(URL(string: "https://session/abc")!, scheme: "hermes") == nil)
        #expect(NotificationRules.link(URL(string: "hermes://composio/x")!, scheme: "hermes") == nil)
    }

    @Test func aTapOpensTheStoredChatLocalOrPushed() {
        let local = NotificationText.localInfo(session: "a1b2c3d4", stored: "20261003_101500_ab12cd", request: "", kind: "message.complete", profile: "ivy")
        #expect(NotificationRules.target(local)?.session == "20261003_101500_ab12cd" && NotificationRules.target(local)?.profile == "ivy")
        #expect(NotificationRules.target(["dispatch": ["session": "s_1", "profile": "ops"]])?.session == "s_1")
        #expect(NotificationRules.target(["session": "bad id"]) == nil)
        #expect(NotificationRules.target(["session": "20261003"])?.profile == nil)
    }

    // UX study #261, #262: a pushed alert keeps its own kind, and says which gateway account it came from.
    @Test func aPushedAlertsKindAndAccount() {
        #expect(NotificationRules.pushedKind(["kind": "approval"]) == "approval.request")
        #expect(NotificationRules.pushedKind(["kind": "turnDone"]) == "message.complete")
        #expect(NotificationRules.pushedKind([:]) == "message.complete", "a plugin too old to say sends replies")
        #expect(NotificationRules.pushedKind(["kind": "input"]) == "input")
        #expect(NotificationRules.pushedKind(["kind": "turnError"]) == "turnError")
        #expect(NotificationRules.account(["dispatch": ["account": "abc"]]) == "abc")
        #expect(NotificationRules.account(["dispatch": ["account": ""]]) == nil && NotificationRules.account(["session": "s"]) == nil)
    }

    // UX study #260: a follow-up about a pushed answer names the command its alert showed.
    @Test func aFailedAnswerNamesTheCommand() {
        #expect(NotificationText.shownCommand("Wants to run: git push") == "git push")
        #expect(NotificationText.shownCommand("Ivy needs your approval") == "")
        #expect(PushRegistrar.failureWords(.failed, resolved: false, command: "git push", app: "Hermes HQ")
                == "Your answer to “git push” wasn’t sent. Open Hermes HQ to review it.")
        #expect(PushRegistrar.failureWords(.failed, resolved: false, app: "Hermes HQ") == "Couldn’t answer that request. Open Hermes HQ to review it.")
        #expect(PushRegistrar.failureWords(.stale, resolved: false, command: "ls", app: "Hermes HQ") == PushRegistrar.otherGatewayWords)
    }

    @Test func messagesRulesForWhichChatsAlert() {
        #expect(NotificationRules.shouldPost(session: "S", active: false, viewing: "S", viewingStored: "S"), "away: everything alerts")
        #expect(!NotificationRules.shouldPost(session: "S", active: true, viewing: nil, viewingStored: "S"), "the chat on screen doesn't")
        #expect(NotificationRules.shouldPost(session: "T", active: true, viewing: nil, viewingStored: "S"), "another chat does")
        #expect(NotificationRules.shouldPost(session: "T", active: true, viewing: nil, viewingStored: nil), "on a list every chat does")
        #expect(NotificationRules.relevance(kind: "approval.request", session: "S", viewing: nil) == 1)
        #expect(NotificationRules.relevance(kind: "turnDone", session: "S", viewing: "S") == 0.9)
        #expect(NotificationRules.relevance(kind: "turnDone", session: "T", viewing: "S") == 0.6)
    }

    @Test func categoriesOfferApproveOnceWithUnlockAndDeny() {
        let categories = NotificationHub.categories()
        #expect(categories.map(\.identifier) == ["DISPATCH_APPROVAL", "DISPATCH_APPROVAL_LOCAL"])
        let pushed = categories[0].actions
        #expect(pushed.map(\.identifier) == ["approve", "deny"] && pushed[0].title == "Approve Once")
        #expect(pushed[0].options.contains(.authenticationRequired) && pushed[1].options.contains(.destructive))
        #expect(!pushed[0].options.contains(.foreground), "a pushed approval answers without opening the app")
        #expect(categories[1].actions.allSatisfy { $0.options.contains(.foreground) }, "a local one opens the app to answer")
    }
}

@Suite struct ValueRequestAlertTests {
    private func params(_ json: String) throws -> JSONValue { try JSONValue.parse(Data(json.utf8)) }

    @Test func eachRequestSaysWhatItWants() throws {
        #expect(NotificationText.valueRequestLine(.secret, params: try params(#"{"prompt":"Your OpenWeather key"}"#)) == "Your OpenWeather key")
        #expect(NotificationText.valueRequestLine(.secret, params: try params("{}")) == "A password or secret is needed")
        #expect(NotificationText.valueRequestLine(.sudo, params: try params(#"{"command":"apt update"}"#)) == "Your administrator password is needed")
        #expect(NotificationText.valueRequestLine(.vaultUnlock, params: try params(#"{"display_name":"1Password"}"#)) == "Unlock 1Password to continue")
        #expect(NotificationText.valueRequestLine(.vaultUnlock, params: try params("{}")) == "Unlock your password manager to continue")
        #expect(NotificationText.valueRequestLine(.vaultSaveLogin, params: try params(#"{"site":"GitHub"}"#)) == "Save your GitHub login?")
        #expect(NotificationText.valueRequestLine(.vaultSaveLogin, params: try params("{}")) == "Save a login?")
        #expect(NotificationText.valueRequestLine(.vaultCode, params: try params(#"{"site":"GitHub"}"#)) == "A verification code for GitHub is needed")
        #expect(NotificationText.valueRequestLine(.vaultCode, params: try params(#"{"site":"  "}"#)) == "A verification code is needed")
    }
}

@Suite struct BadgeTests {
    private func bot(_ id: String, unread: Bool, hidden: Bool = false, chat: String? = nil) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: unread, pinned: false,
            pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: chat, head: nil)
    }
    private func session(_ id: String, unread: Bool) -> SessionSummary {
        SessionSummary(id: id, profile: "default", title: id, preview: nil, lastActive: nil, source: nil, unread: unread, isRunning: false)
    }

    @Test func iconBadgeIsBotsTabPlusSessionsTab() {
        let ids = BadgeMath.ids(bots: [bot("ivy", unread: true, chat: "s_ivy"), bot("ops", unread: true), bot("old", unread: true, hidden: true),
                                       bot("idle", unread: false)],
                                sessions: [session("s_1", unread: true), session("s_2", unread: false), session("s_ivy", unread: true),
                                           session("s_run", unread: true)],
                                visible: { $0.id != "s_run" })
        #expect(ids == ["s_ivy", "bot:ops", "s_1"], "hidden bots and hidden runs don't count; a bot's chat counts once")
    }

    @Test func backCountReadsLikeMessages() {
        #expect(BadgeMath.backTitle(0) == nil && BadgeMath.backTitle(3) == "3" && BadgeMath.backTitle(120) == "99+")
        #expect(BadgeMath.badge(99) == "99" && BadgeMath.badge(100) == "99+" && BadgeMath.badge(1234) == "99+", "badges are capped (audit 05-19)")
    }

    @Test func alertsWhileAwayAddToTheListsCountUntilBack() {
        var badge = NotificationBadge()
        badge.markers(["s_1"], enabled: true, active: true)
        #expect(badge.alert(kind: "message.complete", chat: "s_2", active: false) && badge.count == 2)
        #expect(!badge.alert(kind: "approval.request", chat: "s_3", active: false) && badge.count == 2)
        #expect(badge.alert(kind: "message.complete", chat: "s_1", active: false) && badge.count == 2, "one chat once")
        badge.becameActive()
        badge.markers(["s_1"], enabled: true, active: true)
        #expect(badge.count == 1)
    }
}

@Suite(.serialized) struct NotificationPrefsTests {
    @Test func readsTheWebAppsPrefsAndDefaultsToAllOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "hqn.tests.notification-prefs"))
        defaults.removePersistentDomain(forName: "hqn.tests.notification-prefs")
        let fresh = NotificationPrefs.load(defaults)
        #expect(fresh.enabled && fresh.previews && NotificationPrefs.kinds.allSatisfy { fresh.allows($0) })
        // As the web app (build 240) left it in UserDefaults: an update keeps the choices.
        defaults.set(["enabled": true, "kinds": ["approval": true, "turnDone": false], "previews": false], forKey: NotificationPrefs.key)
        let web = NotificationPrefs.load(defaults)
        #expect(web.enabled && !web.previews && !web.allows("turnDone") && web.allows("approval") && web.allows("input"))
        var changed = web
        changed.enabled = false
        changed.save(defaults)
        #expect(!NotificationPrefs.load(defaults).allows("approval"))
        #expect(NotificationPrefs.preference("message.complete") == "turnDone" && NotificationPrefs.preference("approval.request") == "approval")
        #expect(NotificationPrefs.testBlocker(denied: false, prefs: web) == "Turn on Response Ready to send a test.")
        #expect(NotificationPrefs.testBlocker(denied: false, prefs: changed) == "Turn on Enable Notifications to send a test.")
        #expect(NotificationPrefs.testBlocker(denied: true, prefs: fresh)?.hasPrefix("Allow notifications for") == true)
        #expect(NotificationPrefs.testBlocker(denied: false, prefs: fresh) == nil)
    }

    /// [addon-reminder] The launch alert offers an add-on level once; after Not Now only a newer level asks again.
    @Test func setupIsOfferedOncePerAddOnLevel() {
        #expect(PushSetupOffer.shouldOffer(state: .missing, account: "O", offered: nil, level: "0.9.16/0.9.12", fromSettings: false))
        #expect(PushSetupOffer.shouldOffer(state: .outdated, account: "O", offered: nil, level: "0.9.16/0.9.12", fromSettings: false))
        #expect(!PushSetupOffer.shouldOffer(state: .outdated, account: "O", offered: "0.9.16/0.9.12", level: "0.9.16/0.9.12", fromSettings: false),
                "said Not Now to this level: no alert again, only the quiet reminder")
        #expect(PushSetupOffer.shouldOffer(state: .outdated, account: "O", offered: "0.9.16/0.9.12", level: "0.9.17/0.9.12", fromSettings: false),
                "a build that asks for more offers once more")
        #expect(PushSetupOffer.shouldOffer(state: .missing, account: "O", offered: "0.9.16/0.9.12", level: "0.9.16/0.9.12", fromSettings: true))
        #expect(!PushSetupOffer.shouldOffer(state: .ready, account: "O", offered: nil, fromSettings: true))
        #expect(!PushSetupOffer.shouldOffer(state: .unknown, account: "O", offered: nil, fromSettings: true))
        #expect(!PushSetupOffer.shouldOffer(state: .missing, account: nil, offered: nil, fromSettings: true))
        #expect(PushPolicy.offerLevel == PushPolicy.wantedVersion + "/" + PushPolicy.everyBotVersion)
        #expect(PushSetupOffer.prompt.contains("hermes plugins install mrcharlesiv/hermes-hq-plugins/hermes-hq-push --enable"))
        #expect(PushSetupOffer.prompt.contains("not through launchctl submit"))
        #expect(PushSetupOffer.prompt.contains("hermes -p <profile> plugins install mrcharlesiv/hermes-hq-plugins/hermes-hq-push --enable"))
        #expect(!PushSetupOffer.prompt.contains("One install covers every bot"))
    }

    /// [setup-browser] A first setup brings Watch Browser's add-on (one tap, one restart); an update offer and Hermes
    /// Cloud (its bots browse in Browser Use's cloud) don't. The restart request has the bot check for a Chrome.
    @MainActor @Test func firstSetupBringsTheBrowserAddOn() {
        let own = URL(string: "https://studio.tail1234.ts.net")!
        let cloud = URL(string: "https://hermes-cloud-1234.agents.nousresearch.com")!
        #expect(PushSetupOffer.bringsBrowser(state: .missing, gateway: own))
        #expect(!PushSetupOffer.bringsBrowser(state: .missing, gateway: cloud))
        #expect(!PushSetupOffer.bringsBrowser(state: .outdated, gateway: own))
        #expect(!PushSetupOffer.bringsBrowser(state: .ready, gateway: own))
        let both = PushSetupOffer.restartPrompt(browser: true)
        #expect(both.contains("hermes-hq-browser") && both.contains("don't install it per profile"))
        #expect(both.contains("don't install one unless I ask"))
        #expect(both.contains("not through launchctl submit"), "still one restart, run once")
        #expect(!PushSetupOffer.restartPrompt().contains("hermes-hq-browser"))
    }

    /// Hermes loads a bot's add-ons from its own folder only: each bot needs its own current, switched-on copy.
    @Test func everyBotNeedsItsOwnCopy() {
        func row(_ name: String, _ version: String, on: Bool = true) -> PluginInfo {
            PluginInfo.read(.object(["name": .string(name), "version": .string(version), "status": .string(on ? "enabled" : "disabled")]))!
        }
        #expect(PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.54")]) && PushPolicy.botHasPlugin([row("x", "1"), row("hermes-hq-push", "0.10.0")]))
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.11")]), "0.9.11 has no question cards")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.16")]), "0.9.16: a bot another bot messaged can't ask for a login")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.17")]), "0.9.17: the bot can ask for whichever tab is in front")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.18")]), "0.9.18: the bot has no Device Access tools")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.20")]), "0.9.20: the bot has the Contacts tool only")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.21")]), "0.9.21: the bot's steps never reach a Lock Screen card")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.22")]), "0.9.22: a long reply's end can be held back by iOS")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.23")]), "0.9.23: a quick reply's Done card stays up 15 minutes")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.24")]), "0.9.24: the bot has no task tools, so its chats can't add to Tasks")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.41")]), "0.9.41: a job's pictures can drop out of the bot's Bot Chat summary")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.43")]), "0.9.43: a login card can name another site's tab")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.44")]), "0.9.44: the daily Task ideas run is turned away")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.46")]), "0.9.46: the bot has no draft_message, so it can't show a draft card")
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.54", on: false)]) && !PushPolicy.botHasPlugin([]))
        // [tiles] A bot reads the tile skill from its own copy: one from before the kit (0.9.50) still writes the page itself.
        #expect(!PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.49")]))
        // [helper-alerts] The alert for a helper's approval goes from the bot's own copy: before 0.9.54 it opens the helper's page.
        #expect(PushPolicy.everyBotVersion == "0.9.54" && !PushPolicy.botHasPlugin([row("hermes-hq-push", "0.9.53")]))
        #expect(PushPolicy.versionAtLeast(PushPolicy.wantedVersion, PushPolicy.everyBotVersion), "the update on offer satisfies every bot")
        #expect(!PushPolicy.botHasPlugin([row("dispatch-push", "0.9.12")]))
        #expect(PushPolicy.versionAtLeast("0.9.12", "0.9.9") && PushPolicy.versionAtLeast("0.9.12", "0.9.12") && PushPolicy.versionAtLeast("1.0", "0.9.12"))
        #expect(!PushPolicy.versionAtLeast("0.9.9", "0.9.12") && !PushPolicy.versionAtLeast("", "0.9.12") && !PushPolicy.versionAtLeast("0.9.x", "0.9.1"))
        func bot(_ name: String) -> Bot {
            Bot(id: name.lowercased(), name: name, role: nil, preview: nil, lastActive: nil, isWorking: false, unread: false, pinned: false,
                pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
        }
        #expect(PushSetupOffer.names([bot("Gym")]) == "Gym")
        #expect(PushSetupOffer.names([bot("Gym"), bot("Ivy")]) == "Gym and Ivy")
        #expect(PushSetupOffer.names([bot("Gym"), bot("Ivy"), bot("Otto"), bot("Home")]) == "Gym, Ivy and 2 more")
    }

    /// [addon-reminder] What the gateway says becomes the reminder; a failed read changes nothing; kept per account.
    @MainActor @Test func addOnReminderFollowsTheGateway() throws {
        let defaults = try #require(UserDefaults(suiteName: "addon-reminder-\(UUID().uuidString)"))
        #expect(AddOnReminder.need(state: .ready, without: []) == nil)
        #expect(AddOnReminder.need(state: .ready, without: ["Otto"]) == .bots(["Otto"]))
        #expect(AddOnReminder.need(state: .outdated, without: []) == .outdated)
        #expect(AddOnReminder.need(state: .missing, without: []) == .missing)
        #expect(AddOnReminder.need(state: .unknown, without: []) == nil)

        let reminder = AddOnReminder(defaults: defaults)
        reminder.report(account: "A", state: .outdated, without: [])
        #expect(reminder.need == .outdated && reminder.title == "Add-on Update Available")
        reminder.report(account: "A", state: .unknown, without: [])
        #expect(reminder.need == .outdated, "a failed read neither sets nor clears it")
        reminder.use(account: "B")
        #expect(reminder.need == nil, "another gateway has its own")
        reminder.use(account: "A")
        #expect(reminder.need == .outdated, "kept for the next launch")
        let later = AddOnReminder(defaults: defaults)
        later.use(account: "A")
        #expect(later.need == .outdated, "there the moment the app opens")
        later.report(account: "A", state: .ready, without: ["Otto", "Inbox"])
        #expect(later.footer?.hasPrefix("Otto and Inbox don’t have Hermes’s add-on") == true)
        later.report(account: "A", state: .ready, without: [])
        #expect(later.need == nil && later.title == nil)
        later.report(account: "A", state: .missing, without: [])
        #expect(later.title == "Add-on Needed")
        later.signOut(account: "A")
        #expect(later.need == nil && defaults.data(forKey: "push.addOnReminder.A") == nil)
    }

    /// [addon-progress] An update that found the newest add-on older than this build needs: the row says "not out
    /// yet" without the red count for a day, a newer need asks afresh, and nothing needed clears it.
    @MainActor @Test func addOnNotOutHoldsADay() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let want = PushSetupOffer.neededVersion(main: true)
        #expect(AddOnReminder.notOutHolds(want: want, at: start, now: start.addingTimeInterval(60), needed: want))
        #expect(!AddOnReminder.notOutHolds(want: want, at: start, now: start.addingTimeInterval(25 * 3600), needed: want), "a day later it counts again")
        #expect(!AddOnReminder.notOutHolds(want: "0.9.1", at: start, now: start, needed: want), "a newer build needs a newer one")
        #expect(!AddOnReminder.notOutHolds(want: want, at: start, now: start.addingTimeInterval(-60), needed: want), "a clock set back")
        #expect(PushSetupOffer.neededVersion(main: false) == PushPolicy.everyBotVersion)
        #expect(PushPolicy.versionAtLeast(PushSetupOffer.neededVersion(main: true), PushPolicy.wantedVersion))
        #expect(PushPolicy.versionAtLeast(PushSetupOffer.neededVersion(main: true), PushPolicy.everyBotVersion))

        let defaults = try #require(UserDefaults(suiteName: "addon-notout-\(UUID().uuidString)"))
        var clock = start
        let reminder = AddOnReminder(defaults: defaults)
        reminder.now = { clock }
        reminder.report(account: "A", state: .outdated, without: [])
        #expect(reminder.badged && reminder.spoken == "Add-on update available")
        reminder.noteNotOut(account: "A", want: want)
        #expect(!reminder.badged && reminder.spoken == nil, "nothing to update to: no red count")
        #expect(reminder.title == "Add-on \(want) Not Out Yet")
        #expect(reminder.footer?.hasSuffix("Tap to check again.") == true)
        reminder.report(account: "A", state: .outdated, without: [])
        #expect(reminder.notOut == want, "a later read of the same need keeps it")

        let relaunched = AddOnReminder(defaults: defaults)
        relaunched.now = { clock }
        relaunched.use(account: "A")
        #expect(relaunched.notOut == want && !relaunched.badged, "kept across launches")
        clock = start.addingTimeInterval(25 * 3600)
        let nextDay = AddOnReminder(defaults: defaults)
        nextDay.now = { clock }
        nextDay.use(account: "A")
        #expect(nextDay.notOut == nil && nextDay.badged && nextDay.title == "Add-on Update Available")

        nextDay.noteNotOut(account: "A", want: want)
        nextDay.report(account: "A", state: .ready, without: [])
        #expect(nextDay.notOut == nil && nextDay.need == nil)
        #expect(defaults.dictionary(forKey: "push.addOnReminder.notOut.A") == nil, "the update came out and went in")
        nextDay.report(account: "A", state: .outdated, without: [])
        #expect(nextDay.badged, "a new need counts again")
        nextDay.noteNotOut(account: "A", want: want)
        nextDay.signOut(account: "A")
        #expect(nextDay.notOut == nil && defaults.dictionary(forKey: "push.addOnReminder.notOut.A") == nil)
    }

    /// [manual-restart] A Hermes its owner restarts themselves (sudo): the choice is kept per gateway, the sheet ends on
    /// "Restart Hermes to Finish" with the restart still open, and the app goes on watching after the sheet closes.
    @MainActor @Test func ownerRestartsHermesThemselves() throws {
        let defaults = try #require(UserDefaults(suiteName: "manual-restart-tests"))
        defaults.removePersistentDomain(forName: "manual-restart-tests")
        #expect(!AddOnUpdate.restartsByHand(account: "A", defaults: defaults) && !AddOnUpdate.restartsByHand(account: nil, defaults: defaults))
        AddOnUpdate.setRestartsByHand(true, account: "A", defaults: defaults)
        #expect(AddOnUpdate.restartsByHand(account: "A", defaults: defaults) && !AddOnUpdate.restartsByHand(account: "B", defaults: defaults))
        AddOnUpdate.setRestartsByHand(false, account: "A", defaults: defaults)
        #expect(!AddOnUpdate.restartsByHand(account: "A", defaults: defaults) && defaults.dictionary(forKey: AddOnUpdate.byHandKey) == nil)

        let update = AddOnUpdate()
        update.found(setUp: false, why: "", bot: "Hermes", both: false)
        update.work()
        update.step(.install, .done)
        update.step(.restart, .active, detail: AddOnUpdate.youRestart)
        update.watch(true)
        update.end(.yours)
        #expect(update.headline == "Restart Hermes to Finish" && update.showsSteps && update.hasAction && update.busy)
        #expect(update.steps.first { $0.id == .restart }?.state == .active, "the restart is still open")
        #expect(update.steps.first { $0.id == .restart }?.detail == AddOnUpdate.youRestart)
        #expect(update.rowStatus == "Restart Hermes to Finish", "Settings' row says what is left")
        let line = try #require(update.line)
        #expect(line.hasPrefix("The add-on is installed.") && line.contains("hermes dashboard or hermes serve") && !line.contains("chat"))
        #expect(AddOnUpdate.line(.yours, bot: "Hermes", addOns: .both).hasPrefix("Both add-ons are installed."))
        #expect(AddOnUpdate.line(.yours, bot: "Hermes", addOns: .browser).hasPrefix("The browser add-on is installed."))
        update.sheetClosed()
        #expect(update.phase == .ended(.yours), "closing the sheet leaves the watch going")
        // Hermes came back: the same ending as a restart the bot did.
        update.complete([.install, .restart])
        update.work()
        update.step(.verify, .active, detail: AddOnUpdate.eachBot)
        update.watch(false)
        update.end(.on(version: "0.9.49"))
        #expect(update.steps.allSatisfy { $0.state == .done } && update.headline == "Add-on 0.9.49 Is On" && !update.busy)

        #expect(AddOnUpdate.askInstead("Ivy") == "Ask Ivy Instead")
        #expect(AddOnUpdate.byHandNote("Ivy", on: false).contains("Ivy restarts it") && !AddOnUpdate.byHandNote("Ivy", on: true).contains("Ivy"))
        #expect(PushSetupOffer.restartNote(bot: "Ivy", byHand: true) == "Then you restart Hermes on its computer, and the app finishes once it’s back.")
        #expect(PushSetupOffer.restartNote(bot: "Ivy").contains("Ivy’s chat opens"))
        #expect(!AddOnUpdate.notRestartedReason.contains("chat"))
        // The watch: every 3 s, then every 20 s, then once a minute for the rest of the day.
        let began = Date(timeIntervalSince1970: 0)
        #expect(PushSetupOffer.watchTicks(since: began, now: began.addingTimeInterval(60)) == 6)
        #expect(PushSetupOffer.watchTicks(since: began, now: began.addingTimeInterval(5 * 60)) == 40)
        #expect(PushSetupOffer.watchTicks(since: began, now: began.addingTimeInterval(16 * 60)) == 120)
        #expect(PushSetupOffer.byHandWatch == 86_400)
    }

    /// [addon-progress] The update sheet's steps and words through an update, and what a second tap finds.
    @MainActor @Test func addOnUpdateWalksTheSteps() {
        let update = AddOnUpdate()
        #expect(!update.busy && update.rowStatus == nil)
        update.found(setUp: false, why: AddOnReminder.footer(.outdated), bot: "Hermes", both: false)
        #expect(update.steps.map(\.id) == [.check, .install, .restart, .verify])
        #expect(update.steps.map(\.title) == ["Check Hermes", "Install the update", "Restart Hermes", "Check it’s on"])
        #expect(update.steps.first?.state == .done && update.steps.dropFirst().allSatisfy { $0.state == .waiting })
        #expect(update.steps.first { $0.id == .restart }?.detail == AddOnUpdate.restartPlan("Hermes"), "the question says the bot's chat opens")
        for need in [AddOnReminder.Need.missing, .outdated, .bots(["Finance", "Gym"])] {
            for both in [false, true] {
                #expect(AddOnUpdate.why(need, both: both).count <= 160, "one short line on what it is and why (the owner: too much to read)")
            }
        }
        #expect(AddOnUpdate.installPlan(bots: [], all: 11) == "For all 11 bots" && AddOnUpdate.installPlan(bots: [], all: 1) == nil)
        #expect(AddOnUpdate.installPlan(bots: ["Finance", "Gym"], all: 11) == "For Finance and Gym")
        #expect(AddOnUpdate.why(.bots(["Gym"]), both: false).hasPrefix("Gym doesn’t have the add-on yet"))

        update.work()
        update.step(.install, .active, detail: AddOnUpdate.installing("Finance", 4, of: 11))
        #expect(update.busy, "a second tap shows the sheet instead of starting again")
        #expect(update.headline == "Updating…" && update.line == AddOnUpdate.keepsGoing)
        #expect(update.rowStatus == "Install the update: Finance · 4 of 11")
        update.step(.install, .done)
        update.step(.restart, .active, detail: AddOnUpdate.botRestarts("Hermes"))
        #expect(update.headline == "Restarting Hermes…" && update.showsSteps && !update.hasAction)
        #expect(update.steps.first { $0.id == .install }?.detail == nil, "a finished step drops its note")

        // Four minutes and no restart: the sheet says so, the restart keeps its spinner, the app keeps watching.
        update.watch(true)
        update.end(.slow)
        #expect(update.busy && update.hasAction && update.headline == "Hermes Hasn’t Restarted Yet")
        #expect(update.steps.first { $0.id == .restart }?.state == .active)
        update.sheetClosed()
        #expect(update.phase == .ended(.slow), "closing a slow sheet leaves the watch going")

        update.complete([.install, .restart])
        update.step(.verify, .active, detail: AddOnUpdate.eachBot)
        update.watch(false)
        update.end(.on(version: "0.9.32"))
        #expect(update.steps.allSatisfy { $0.state == .done } && update.headline == "Add-on 0.9.32 Is On")
        #expect(!update.busy && update.rowStatus == nil)
        update.sheetClosed()
        #expect(update.phase == .idle)

        // The newest add-on out is older than this build needs: no steps left spinning, no button, words say why.
        update.found(setUp: false, why: "", bot: "Hermes", both: false)
        update.work()
        update.step(.install, .done)
        update.end(.notOut(have: "0.9.31", want: "0.9.32"))
        #expect(update.headline == "Add-on 0.9.32 Isn’t Out Yet" && !update.showsSteps && !update.hasAction && !update.busy)
        #expect(AddOnUpdate.line(.notOut(have: "0.9.31", want: "0.9.32"), bot: "Hermes").contains("the newest one out is 0.9.31"))
        #expect(!update.steps.contains { $0.state == .active })
        #expect(update.steps.filter { $0.state == .waiting }.allSatisfy { $0.detail == nil }, "no plan left under a step that won't happen")

        // A first setup that brings Watch Browser's add-on too.
        update.found(setUp: true, why: "", bot: "Hermes", both: true)
        #expect(AddOnUpdate.installTitle(setUp: true, both: true) == "Install the add-ons")
        update.reset()
        #expect(update.phase == .idle && update.steps.isEmpty && !update.busy)
    }
}

// MARK: - Registration against a stand-in plugin

@MainActor private final class FakePlugin {
    var status: Int = 200
    var statusBody: [String: Any] = ["ok": true, "kinds": ["turnDone", "approval"], "seal": true, "replies": "watcher", "ownChats": true, "quietStandIns": true, "desktopOpens": true, "askCards": true, "pagePreviews": true, "warmup": true, "desktopForward": true, "gatewayLogins": true, "namedSites": true, "deviceAccess": true, "deviceAccessKinds": true, "liveSteps": true, "liveEnds": true, "liveQuick": true, "terminal": true, "tasks": true, "draftCards": true, "pluginUpdates": true, "task_fields": true, "draftCardsShown": true, "pluginVersion": "0.9.54", "delivery": "Relay"]
    var legacyStatus: Int = 404
    var calls: [(path: String, method: String, body: [String: Any]?)] = []
    var deviceStatus = 200
    var approvalAnswer: (Int, [String: Any]?) = (200, ["ok": true, "resolved": 1])

    var call: PushRegistrar.Call {
        { [unowned self] path, method, body in
            self.calls.append((path, method, body))
            if path.hasPrefix(PushPolicy.legacyRoute) { return (self.legacyStatus, self.legacyStatus == 200 ? self.statusBody : nil) }
            if path.hasSuffix("/status") { return (self.status, self.status == 200 ? self.statusBody : nil) }
            if path.contains("/devices/") { return (self.deviceStatus, ["ok": true]) }
            if path.contains("/approvals/") { return self.approvalAnswer }
            return (404, nil)
        }
    }
}

/// Holds a stand-in plugin call until the test lets it answer.
@MainActor private final class PushGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /// A call is held (within about 2 s).
    func reached() async -> Bool {
        for _ in 0..<100 where continuation == nil { try? await Task.sleep(for: .milliseconds(20)) }
        return continuation != nil
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor @Suite(.serialized) struct PushRegistrarTests {
    private let owner = String(repeating: "ab", count: 32)

    private func registrar(_ name: String) -> (PushRegistrar, UserDefaults) {
        let suite = "hqn.tests.push.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let push = PushRegistrar(defaults: defaults)
        push.availableOverride = true
        push.isAuthorized = { true }
        push.received(token: Data(repeating: 0xab, count: 32))
        return (push, defaults)
    }

    @Test func registersWithSealKeyKindsPreviewsAndTopic() async throws {
        let (push, defaults) = registrar("register")
        let plugin = FakePlugin()
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        var prefs = NotificationPrefs()
        prefs.kinds = ["approval": false]
        prefs.previews = false
        prefs.save(defaults)
        await push.register()
        let put = try #require(plugin.calls.first { $0.method == "PUT" })
        #expect(put.path == PushPolicy.route + "/devices/" + PushRegistrar.deviceID)
        let body = try #require(put.body)
        #expect(body["token"] as? String == String(repeating: "ab", count: 32))
        #expect(body["environment"] as? String == "sandbox")
        #expect(body["topic"] as? String == Bundle.main.bundleIdentifier)
        #expect(body["account"] as? String == owner && body["profile"] as? String == "*")
        #expect(body["kinds"] as? [String: Bool] == ["turnDone": true, "approval": false, "outside": false])
        #expect(body["previews"] as? Bool == false)
        let seal = try #require((body["seal"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(seal.count == 32 && PushSealKeys.all().contains(seal), "the key the plugin seals with is the one the extension reads")
        #expect(push.active && push.delivers("message.complete") && !push.delivers("approval.request"))
        #expect(push.lastPluginState == .ready)
    }

    /// [drafts] An add-on with draft_message that hasn't heard from an app that draws the card is told once; one that
    /// has heard is left alone.
    @Test func tellsTheAddOnThisAppDrawsDraftCards() async throws {
        let (push, _) = registrar("drafts")
        let plugin = FakePlugin()
        plugin.statusBody["draftCardsShown"] = false
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        let cards = PushPolicy.route + DraftCards.cardsPath
        #expect(plugin.calls.contains { $0.method == "PUT" && $0.path == cards })
        #expect(push.lastPluginState == .ready, "the card call's answer doesn't change what the add-on is")
        plugin.calls = []
        plugin.statusBody["draftCardsShown"] = true
        await push.register()
        #expect(!plugin.calls.contains { $0.path == cards })
    }

    @Test func outsideChatsAskForThoseChatsAlerts() async throws {
        let (push, defaults) = registrar("outside")
        let plugin = FakePlugin()
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        push.outsideChats = { true }
        await push.register()
        let body = try #require(plugin.calls.first { $0.method == "PUT" }?.body)
        #expect((body["kinds"] as? [String: Bool])?["outside"] == true)
        var prefs = NotificationPrefs.load(defaults)
        prefs.kinds["outside"] = false
        prefs.save(defaults)
        await push.register()
        let off = try #require(plugin.calls.last { $0.method == "PUT" }?.body)
        #expect((off["kinds"] as? [String: Bool])?["outside"] == false, "Settings › Notifications › Outside Chats off")
    }

    @Test func aMissingPluginLeavesLocalAlertsAndAnOldOneIsOutdated() async {
        let (push, _) = registrar("missing")
        let plugin = FakePlugin()
        plugin.status = 404
        push.call = plugin.call
        push.setOwner(owner)
        await push.register()
        #expect(!push.active && push.lastPluginState == .missing && !plugin.calls.contains { $0.method == "PUT" })
        #expect(plugin.calls.map(\.path) == [PushPolicy.route + "/status", PushPolicy.legacyRoute + "/status"])
        plugin.legacyStatus = 200
        let state = await push.pluginState()
        #expect(state.state == .outdated, "an old dispatch-push is offered the update")
    }

    @Test func notificationsOffOrSignOutRemovesTheDevice() async {
        let (push, defaults) = registrar("remove")
        let plugin = FakePlugin()
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        #expect(push.active)
        var prefs = NotificationPrefs.load(defaults)
        prefs.enabled = false
        prefs.save(defaults)
        await push.register()
        #expect(plugin.calls.last?.method == "DELETE" && !push.active && !push.retry)
        // A DELETE that never got an answer is still owed after sign-out (the ledger keeps it).
        prefs.enabled = true
        prefs.save(defaults)
        await push.register()
        plugin.deviceStatus = 0
        await push.unregister()
        #expect(push.retry)
        push.clear()
        let saved = PushLedger.decode(defaults.data(forKey: "hermes.push.ledger"))
        #expect(saved.needsRemoval(owner) && saved.owner == nil)
    }

    /// Audit 14-1: a sign-out's DELETE that answers after its 4 s budget (the sign-out has cleared the registrar by
    /// then) still settles the removal; the account's seal key goes with the sign-out, so an alert its gateway still
    /// pushes can't be read here.
    @Test func aLateRemovalAnswerAfterSignOutIsKeptAndTheSealKeyGoes() async throws {
        let (push, defaults) = registrar("late-removal")
        let plugin = FakePlugin()
        let gate = PushGate()
        push.call = { path, method, body in
            if method == "DELETE" { await gate.wait() }
            return await plugin.call(path, method, body)
        }
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        let seal = try #require(PushSealKeys.key(for: owner))
        #expect(push.active && PushSealKeys.all().contains(seal))
        let removal = Task { @MainActor in await push.unregister() }
        #expect(await gate.reached())
        push.clear()                         // the budget ran out: sign-out goes on
        push.call = nil
        #expect(!PushSealKeys.all().contains(seal), "a signed-out phone keeps no key to read that gateway's alerts")
        #expect(PushLedger.decode(defaults.data(forKey: "hermes.push.ledger")).needsRemoval(owner))
        gate.open()
        await removal.value
        #expect(plugin.calls.last?.method == "DELETE")
        #expect(!PushLedger.decode(defaults.data(forKey: "hermes.push.ledger")).needsRemoval(owner), "the late 200 counts")
    }

    /// Audit 14-1: a registration asked for while a removal runs (a switch whose DELETE outlived its budget) runs once
    /// the removal ends, instead of being dropped until the next launch.
    @Test func aRegistrationDuringARemovalRunsAfterIt() async throws {
        let (push, _) = registrar("register-after-removal")
        let plugin = FakePlugin()
        let gate = PushGate()
        push.call = { path, method, body in
            if method == "DELETE" { await gate.wait() }
            return await plugin.call(path, method, body)
        }
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        let removal = Task { @MainActor in await push.unregister() }
        #expect(await gate.reached())
        let puts = plugin.calls.filter { $0.method == "PUT" }.count
        await push.register()
        #expect(plugin.calls.filter { $0.method == "PUT" }.count == puts, "nothing is registered while the removal runs")
        gate.open()
        await removal.value
        var waited = 0
        while plugin.calls.filter({ $0.method == "PUT" }).count == puts, waited < 100 {
            try await Task.sleep(for: .milliseconds(20)); waited += 1
        }
        #expect(plugin.calls.last?.method == "PUT" && push.active)
    }

    /// Review fix 1: Add Gateway signs in elsewhere first (A's client is gone); A's DELETE goes with A's own session.
    @Test func addGatewayLeavesTheOldGatewayWithItsOwnSession() async {
        let (push, defaults) = registrar("add-gateway")
        let pluginA = FakePlugin(), pluginB = FakePlugin()
        let ownerB = String(repeating: "cd", count: 32)
        push.call = pluginA.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner); PushSealKeys.remove(ownerB) }
        await push.register()
        #expect(push.active)
        // B is activated (A still holds the registration, so A is owed a removal), then A's call goes out.
        push.call = pluginB.call
        push.setOwner(ownerB)
        #expect(PushLedger.decode(defaults.data(forKey: "hermes.push.ledger")).needsRemoval(owner))
        pluginA.deviceStatus = 0
        #expect(await push.removeDevice(from: owner, call: pluginA.call) == 0)
        #expect(PushLedger.decode(defaults.data(forKey: "hermes.push.ledger")).needsRemoval(owner), "no answer: still owed")
        pluginA.deviceStatus = 200
        #expect(await push.removeDevice(from: owner, call: pluginA.call) == 200)
        #expect(pluginA.calls.last.map { $0.method == "DELETE" && $0.path.hasSuffix("/devices/" + PushRegistrar.deviceID) } == true)
        #expect(!PushLedger.decode(defaults.data(forKey: "hermes.push.ledger")).needsRemoval(owner))
        #expect(await push.removeDevice(from: owner, call: pluginA.call) == 0, "nothing owed: nothing sent")
        #expect(await push.removeDevice(from: ownerB, call: pluginB.call) == 0, "never the account in use")
        #expect(!pluginB.calls.contains { $0.method == "DELETE" })
    }

    /// Review fix 2: a switch that fails after this device left the current gateway registers it again there.
    @Test func aFailedSwitchRegistersAgainWithTheCurrentGateway() async {
        let (push, _) = registrar("failed-switch")
        let plugin = FakePlugin()
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        await push.unregister()          // notificationsLeaving before the switch
        push.call = nil
        #expect(!push.active && plugin.calls.last?.method == "DELETE")
        push.call = plugin.call          // notificationsResume
        await push.register()
        #expect(push.active && plugin.calls.last?.method == "PUT")
    }

    @Test func approveFromAnAlertPostsTheTokenOnceAndOnlyForItsAccount() async throws {
        let (push, defaults) = registrar("approve")
        let plugin = FakePlugin()
        push.call = plugin.call
        push.setOwner(owner)
        defer { PushSealKeys.remove(owner) }
        await push.register()
        let remote: [String: Any] = ["kind": "approval", "session": "s_1", "request": "req_42", "sessionKey": "agent:main:desktop:dm:1",
                                     "token": String(repeating: "f", count: 64), "account": owner]
        await push.answer(remote, choice: "once")
        let post = try #require(plugin.calls.first { $0.method == "POST" })
        #expect(post.path == PushPolicy.route + "/approvals/req_42")
        #expect(post.body?["choice"] as? String == "once" && post.body?["session_key"] as? String == "agent:main:desktop:dm:1"
                && post.body?["token"] as? String == String(repeating: "f", count: 64))
        await push.answer(remote, choice: "deny")
        #expect(plugin.calls.filter { $0.method == "POST" }.count == 1, "only the first tap counts")
        var other = remote
        other["request"] = "req_43"
        other["account"] = String(repeating: "cd", count: 32)
        await push.answer(other, choice: "once")
        #expect(plugin.calls.filter { $0.method == "POST" }.count == 1, "another account's alert is never answered here")
        #expect(PushAnswers.decode(defaults.data(forKey: "hermes.push.answers")).pending.isEmpty)
    }
}

// MARK: - Identity and the web app's sign-in

@Suite(.serialized) struct IdentityTests {
    @Test func identityComesFromInfoPlist() {
        let original = AppIdentity.from(["HQIdentity": "original", "HQKeychainService": "ai.hermes.ios.gateway", "HQSignedOutKey": "dispatch.vault.signedOut",
                                         "HQAppGroup": "group.com.charlesmcdowell.dispatch", "CFBundleDisplayName": "Hermes HQ",
                                         "CFBundleURLTypes": [["CFBundleURLSchemes": ["hermes"]]]], bundleId: "com.charlesmcdowell.dispatch")
        #expect(original == .original && original.canPush)
        let native = AppIdentity.from(["HQIdentity": "native", "HQAppGroup": ""], bundleId: "com.charlesmcdowell.hermeshq.native")
        #expect(native.kind == .native && native.appGroup == nil && !native.canPush && native.keychainService == "ai.hermes.hqnative.gateway")
        #expect(AppIdentity.from([:], bundleId: nil) == .native, "a test host without the keys is native")
        #expect(AppIdentity.current.keychainService == AccountVault.app.service)
    }

    /// [mac] The Mac logged the owner out after updates: a Debug build of the Hermes HQ identity has the download's bundle
    /// ID, so its Keychain group and data folder, and test runs signed it in to stand-in gateways or reset it. Debug Mac
    /// builds keep their own item and mark; Release (the download and the App Store build) keeps the web app's.
    @Test func macDebugBuildsKeepTheirOwnSignIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = project.split(separator: "\n").map(String.init)
        func block(_ name: String) -> [String] {
            guard let start = lines.firstIndex(where: { $0 == "    \(name):" }) else { return [] }
            return Array(lines[(start + 1)...].prefix { $0.hasPrefix("      ") })
        }
        let debug = block("Debug"), release = block("Release")
        #expect(debug.contains { $0.contains(#""HQ_KEYCHAIN_SERVICE[sdk=macosx*]": $(HQ_KEYCHAIN_SERVICE_$(HQ_IDENTITY)).debug"#) })
        #expect(debug.contains { $0.contains(#""HQ_SIGNED_OUT_KEY[sdk=macosx*]": $(HQ_SIGNED_OUT_KEY_$(HQ_IDENTITY)).debug"#) })
        #expect(!release.contains { $0.contains("HQ_KEYCHAIN_SERVICE") || $0.contains("HQ_SIGNED_OUT_KEY") }, "the download keeps the web app's item")
        // Only Debug overrides it: base names the web app's item for every SDK.
        let overrides = lines.filter { $0.contains("HQ_KEYCHAIN_SERVICE[") }
        #expect(overrides.count == 1)
        // And a Debug reset never empties the download's data folder.
        let hooks = try String(contentsOf: root.appendingPathComponent("App/Debug/DebugHooks.swift"), encoding: .utf8)
        let reset = try #require(hooks.range(of: "guard defaults.bool(forKey: \"HQDebugResetAccounts\")"))
        let wipe = try #require(hooks.range(of: "AccountVault.app.removeAll()"))
        let between = hooks[reset.upperBound..<wipe.lowerBound]
        #expect(between.contains("AppIdentity.current.bundleId == AppIdentity.pushTopic") && between.contains("return"))
    }

    /// The web app's Keychain item (build 240's `SavedAccounts`, written by ios/App/App/HermesNative.swift): a password
    /// gateway with cookies and a Sign in with Nous gateway, the Nous one current. Read by the native vault as is.
    static let webItem = #"""
    {"current":"https:\/\/hermes.example.ts.net\nnous:user-7","accounts":[{"url":"https:\/\/hermes.example.ts.net","username":"nous:user-7","label":"Studio","nous":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":1790000000,"userId":"user-7"}},{"url":"http:\/\/192.168.1.20:9119","username":"alex","cookies":[{"name":"hermes_session","value":"fixture-cookie","domain":"192.168.1.20","path":"\/","expires":1792000000,"secure":false,"httpOnly":true,"sameSite":"Lax"}],"provider":"password"}]}
    """#

    private func write(_ json: String, to vault: AccountVault) {
        vault.removeAll()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vault.service,
                                   kSecAttrAccount as String: vault.account, kSecValueData as String: Data(json.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    @Test func readsTheWebAppsSignInItem() throws {
        let vault = Fixtures.testVault("web-item")
        defer { vault.removeAll() }
        write(Self.webItem, to: vault)
        let saved = try #require(try vault.load())
        #expect(saved.accounts.count == 2)
        let current = try #require(saved.active, "the web app's current key matches the native key rule")
        #expect(current.isNous && current.nous?.refreshToken == "fixture-refresh" && current.nous?.obtainedAt == nil)
        #expect(current.gatewayAccount?.kind == .nous && current.gatewayAccount?.label == "Studio")
        let password = try #require(saved.accounts.last)
        #expect(password.hasSession && password.cookies?.first?.name == "hermes_session" && password.gatewayAccount?.username == "alex")
        // A push registration made by the web app for this account is recognized (same owner hash).
        #expect(PushPolicy.owner(url: current.url, username: current.username) == PushPolicy.owner(url: "https://HERMES.example.ts.net/", username: "nous:user-7"))
    }

    @Test func aPendingWebSignOutIsHonoured() throws {
        let vault = AccountVault(service: "ai.hermes.hqnative.gateway.tests.web-signout", signedOutKey: "hqn.tests.dispatch.vault.signedOut")
        defer { vault.removeAll() }
        write(Self.webItem, to: vault)
        UserDefaults.standard.set(true, forKey: vault.signedOutKey)
        let saved = try vault.load()
        #expect(saved?.active?.username != "nous:user-7", "the account the web app was signing out of is not restored")
        #expect(!UserDefaults.standard.bool(forKey: vault.signedOutKey))
    }

    @Test func readsAnOldSingleAccountItem() throws {
        let vault = Fixtures.testVault("web-item-89")
        defer { vault.removeAll() }
        write(#"{"url":"https://hermes.example.com","username":"alex","password":"old","cookies":[{"name":"c","value":"v","domain":"hermes.example.com","path":"/","secure":true}]}"#, to: vault)
        let saved = try #require(try vault.load())
        #expect(saved.active?.username == "alex" && saved.active?.hasSession == true)
        let reencoded = String(decoding: try saved.encoded(), as: UTF8.self)
        #expect(!reencoded.contains("password"), "an old password is never written back")
    }
}
