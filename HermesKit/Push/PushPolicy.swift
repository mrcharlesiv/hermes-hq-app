// Push rules (port of the web app's DispatchPushPolicy / DispatchPushAnswers / DispatchPushLedger, HermesPlatform.swift,
// build 240). Pure Foundation; PushRegistrar applies them. The ledger and the saved answers keep the web app's
// UserDefaults keys and JSON, so an update from the web app knows which gateway holds this device's registration.

import CryptoKit
import Foundation

nonisolated enum PushPolicy {
    /// The signed-in account, as a hash of the normalized gateway address and the username (never a secret), so
    /// UserDefaults can say which account a registration or a tapped answer belongs to. Same hash as the web app's.
    static func owner(url: String, username: String) -> String {
        var parts = URLComponents(string: url)
        let scheme = parts?.scheme?.lowercased(), host = parts?.host?.lowercased()
        parts?.scheme = scheme; parts?.host = host
        parts?.user = nil; parts?.password = nil; parts?.fragment = nil; parts?.query = nil
        while parts?.path.hasSuffix("/") == true { parts?.path.removeLast() }
        let identity = [parts?.string ?? url, username]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The owner of a saved account (the web app's username for a Nous account is `nous:<id>` too).
    static func owner(_ account: GatewayAccount, storedUsername: String?) -> String {
        owner(url: account.baseURL.absoluteString, username: storedUsername ?? account.username ?? "")
    }

    /// What the plugin's status says it delivers; one that doesn't say delivers both. `delivery: null` delivers nothing.
    static func kinds(_ body: [String: Any]?) -> Set<String> {
        if body?["delivery"] is NSNull { return [] }
        // [prompt-alerts] "input": hermes-hq-push 0.9.5+ alerts a bot waiting for a password, login, code or answer.
        return Set(body?["kinds"] as? [String] ?? ["turnDone", "approval"]).intersection(["turnDone", "approval", "input"])
    }
    static func enabledKinds(_ body: [String: Any]?, preferences: [String: Bool]) -> Set<String> {
        kinds(body).filter { preferences[$0] != false }
    }
    static func delivers(_ kind: String, kinds: Set<String>) -> Bool {
        kinds.contains(kind == "message.complete" ? "turnDone" : kind == "approval.request" ? "approval" : kind)
    }
    /// The plugin seals alerts for a device that gives it a key.
    static func seals(_ body: [String: Any]?) -> Bool { (body?["seal"] as? NSNumber)?.boolValue == true }
    /// A plugin this build can rely on: it seals and alerts for every bot's replies (0.3's `replies: "watcher"`), and
    /// lets a Nous sign-in delete, archive and rename the chats it made (0.9.1's `ownChats`; Hermes refuses them without it),
    /// sends no alert for a bot's "[Notification processed; no additional user-facing response.]" (0.9.9's `quietStandIns`),
    /// lets the Hermes desktop app open the chats this app made (0.9.11's `desktopOpens`; Hermes answers
    /// "Resume failed: not_found" without it, tester report 2026-10-29), has a bot ask a question it needs answered
    /// on a question card rather than in text (0.9.12's `askCards`), keeps the Sessions list fast on a bot with many
    /// scheduled runs (0.9.13's `pagePreviews`; Hermes read every chat's first message for one page, 2 s per list), and
    /// loads every bot in the background after Hermes restarts (0.9.15's `warmup`; the first chat opened sat on
    /// "Waking up…" ~2 minutes, 2026-10-30), and hands this app's message to the gateway when the chat is open in the
    /// desktop app (0.9.16's `desktopForward`; Hermes refused it "open in another Hermes window", tester 2026-10-30), and
    /// lets a bot ask for a login, a one-time code or a password manager's unlock in a turn another bot's message or a
    /// hand-off started: the card shows in this app's copy of the chat (0.9.17's `gatewayLogins`; Hermes refused "this
    /// session cannot ask the user for a login", owner 2026-10-30), and makes a bot name the site when it asks for a login
    /// or a code (0.9.18's `namedSites`; without it the card asked for whichever browser tab was in front, owner 2026-10-30),
    /// and takes Settings › Device Access, a bot looking someone up in this phone's contacts (0.9.19's `deviceAccess`),
    /// and every other kind it shares: location, reminders, calendar, alarms, photos, Health, motion, music and drafts
    /// (0.9.21's `deviceAccessKinds`), and keeps a long reply's Lock Screen card naming its bot's steps while the app is
    /// away (0.9.22's `liveSteps`) and ends it Done when the reply ends (0.9.23's `liveEnds`: its steps used up iOS's
    /// ration of urgent card pushes, so the end was held back and the clock counted on, owner 2026-11-01), and takes a
    /// quick reply's Done card away a minute after it ends (0.9.24's `liveQuick`: the app starts a card for every reply
    /// still going when the phone is left, so a short one mustn't sit at Done for 15 minutes), and opens a shell on the
    /// computer for the Terminal page (0.9.25's `terminal`; only that the add-on says whether it can, since a Windows
    /// computer with 0.9.25 says false and must not be offered the update forever).
    static func current(_ body: [String: Any]?) -> Bool {
        seals(body) && body?["replies"] as? String == "watcher" && ownChats(body) && quietStandIns(body) && desktopOpens(body)
            && askCards(body) && pagePreviews(body) && warmup(body) && desktopForward(body) && gatewayLogins(body)
            && namedSites(body) && deviceAccess(body) && deviceAccessKinds(body) && liveSteps(body) && liveEnds(body)
            && liveQuick(body) && terminalKnown(body) && tasks(body) && cronMedia(body) && namedTabs(body)
            && ideasRun(body) && draftCardsKnown(body) && pluginUpdatesKnown(body) && taskFields(body)
            && helperAlerts(body)
    }
    /// [helper-alerts] hermes-hq-push 0.9.54+ sends a helper's approval or question alert for the chat that started the
    /// helper, where the card waits (tester 2026-11-14: "notifications about required approval redirect me to some
    /// subsession … an empty session"; Hermes hands the add-on the helper's own working session). The alert goes from
    /// each bot's own copy. No flag of its own: the add-on says its version.
    static func helperAlerts(_ body: [String: Any]?) -> Bool {
        (body?["pluginVersion"] as? String).map { versionAtLeast($0, helperAlertsVersion) } ?? false
    }
    static let helperAlertsVersion = "0.9.54"
    /// [tasks-first] hermes-hq-push 0.9.53+ keeps what a task manager's task has: priority, tags, an alert, a start
    /// day, repeat on a task you share with a bot, and your own files and links on it (`task_fields`, `task_files`;
    /// owner 2026-11-12: "complex enough to handle any task or use case"). The main bot's copy serves the list; no bot
    /// needs its own for that. Part of `current` since 0.9.53 was published (2026-11-12 evening).
    static func taskFields(_ body: [String: Any]?) -> Bool { (body?["task_fields"] as? NSNumber)?.boolValue == true }
    /// [plugin-consent] hermes-hq-push 0.9.52+ applies a plugin update the owner approved in the app when Hermes only
    /// takes it from a terminal (it adds Python packages): POST /plugins/update (PluginUpdateConsent). Only that the
    /// add-on says so: Hermes on Windows says false (no terminal to give the command) and must not be offered the
    /// update forever.
    static func pluginUpdatesKnown(_ body: [String: Any]?) -> Bool { body?["pluginUpdates"] is NSNumber }
    /// [drafts] hermes-hq-push 0.9.47+ has `draft_message`: a bot shows a message it wrote for someone else as a draft
    /// card with Send, Edit and Don't Send (DraftCards). Only that the add-on says so: one with `drafts.off` says false
    /// and must not be offered the update forever.
    static func draftCardsKnown(_ body: [String: Any]?) -> Bool { body?["draftCards"] is NSNumber }
    /// [cron-media] hermes-hq-push 0.9.42+ keeps a scheduled job's pictures when the bot it reports to sums it up in a Bot
    /// Chat. No flag of its own: the add-on says its version (`pluginVersion`, 0.9.40+).
    static func cronMedia(_ body: [String: Any]?) -> Bool {
        (body?["pluginVersion"] as? String).map { versionAtLeast($0, cronMediaVersion) } ?? false
    }
    static let cronMediaVersion = "0.9.42"
    /// [named-tabs] hermes-hq-push 0.9.44+ asks for a bot's login or one-time code on the site the bot named, never on
    /// another site's tab left open (owner 2026-11-07: on a shop's sign-in the card asked for a hotel site's login;
    /// Hermes asked for the first open tab with a password field). No flag of its own: the add-on says its version.
    static func namedTabs(_ body: [String: Any]?) -> Bool {
        (body?["pluginVersion"] as? String).map { versionAtLeast($0, namedTabsVersion) } ?? false
    }
    static let namedTabsVersion = "0.9.44"
    /// [task-ideas] hermes-hq-push 0.9.45+ lets the daily Task ideas run save its ideas on a Hermes whose scheduler
    /// runs a job in an opaque session (owner 2026-11-08: "the daily check for new task idea isn't working"; every run
    /// since 11-06 was turned away). The ideas bot can be any bot. No flag of its own: the add-on says its version.
    static func ideasRun(_ body: [String: Any]?) -> Bool {
        (body?["pluginVersion"] as? String).map { versionAtLeast($0, ideasRunVersion) } ?? false
    }
    static let ideasRunVersion = "0.9.45"
    /// [tasks] hermes-hq-push 0.9.32+ keeps the shared task list and serves `/tasks` (docs/tasks.md).
    static func tasks(_ body: [String: Any]?) -> Bool { (body?["tasks"] as? NSNumber)?.boolValue == true }
    /// [terminal] hermes-hq-push 0.9.25+ has the Terminal socket: `terminal` says whether this computer can open a shell
    /// (false on Windows), `terminalOff` whether its plugin-data terminal.off turned it off.
    static func terminalKnown(_ body: [String: Any]?) -> Bool { body?["terminal"] is NSNumber }
    static func terminal(_ body: [String: Any]?) -> Bool { (body?["terminal"] as? NSNumber)?.boolValue == true }
    static func terminalOff(_ body: [String: Any]?) -> Bool { (body?["terminalOff"] as? NSNumber)?.boolValue == true }
    static func deviceAccessKinds(_ body: [String: Any]?) -> Bool { (body?["deviceAccessKinds"] as? NSNumber)?.boolValue == true }
    static func deviceAccess(_ body: [String: Any]?) -> Bool { (body?["deviceAccess"] as? NSNumber)?.boolValue == true }
    static func namedSites(_ body: [String: Any]?) -> Bool { (body?["namedSites"] as? NSNumber)?.boolValue == true }
    static func gatewayLogins(_ body: [String: Any]?) -> Bool { (body?["gatewayLogins"] as? NSNumber)?.boolValue == true }
    static func desktopForward(_ body: [String: Any]?) -> Bool { (body?["desktopForward"] as? NSNumber)?.boolValue == true }
    static func warmup(_ body: [String: Any]?) -> Bool { (body?["warmup"] as? NSNumber)?.boolValue == true }
    static func pagePreviews(_ body: [String: Any]?) -> Bool { (body?["pagePreviews"] as? NSNumber)?.boolValue == true }
    static func askCards(_ body: [String: Any]?) -> Bool { (body?["askCards"] as? NSNumber)?.boolValue == true }
    static func desktopOpens(_ body: [String: Any]?) -> Bool { (body?["desktopOpens"] as? NSNumber)?.boolValue == true }
    static func quietStandIns(_ body: [String: Any]?) -> Bool { (body?["quietStandIns"] as? NSNumber)?.boolValue == true }
    static func ownChats(_ body: [String: Any]?) -> Bool { (body?["ownChats"] as? NSNumber)?.boolValue == true }
    static func desktopThemes(_ body: [String: Any]?) -> Bool { (body?["desktopThemes"] as? NSNumber)?.boolValue == true }
    static func restartGuard(_ body: [String: Any]?) -> Bool { (body?["restartGuard"] as? NSNumber)?.boolValue == true }
    /// [live-steps] hermes-hq-push 0.9.22+ takes a reply's Live Activity push token and pushes the bot's steps to its card.
    static func liveSteps(_ body: [String: Any]?) -> Bool { (body?["liveSteps"] as? NSNumber)?.boolValue == true }
    /// [task-ideas] hermes-hq-push 0.9.39+ serves the Tasks page's Ideas (`task_ideas`). Not in `current`: only the
    /// Ideas page asks for it (PushSetupOffer.check's `needsIdeas`), so nobody else is offered an update for it.
    static func taskIdeas(_ body: [String: Any]?) -> Bool { (body?["task_ideas"] as? NSNumber)?.boolValue == true }
    /// [task-ideas] The first add-on with Ideas: what the Ideas page's update asks of the main copy and every bot's
    /// (the daily look runs in the chosen bot's own copy, with its tool and guard).
    static let ideasVersion = "0.9.39"
    /// [live] hermes-hq-push 0.9.23+ pushes those steps at priority 5 and only the turn's end at 10 (and again at 5).
    static func liveEnds(_ body: [String: Any]?) -> Bool { (body?["liveEnds"] as? NSNumber)?.boolValue == true }
    /// [live] hermes-hq-push 0.9.24+ dismisses a Done card a minute after a reply that ran under a minute.
    static func liveQuick(_ body: [String: Any]?) -> Bool { (body?["liveQuick"] as? NSNumber)?.boolValue == true }

    /// Every bot needs its own copy: Hermes loads a bot's add-ons from that bot's folder only, so the main bot's copy
    /// sends reply alerts for all of them (one watcher per computer) but a bot without its own sends no approval or
    /// question alerts and doesn't ask on a question card. 0.9.12 is the first with question cards (`askCards`); 0.9.17
    /// the first whose copy lets that bot ask for a login when another bot's message started its turn (`gatewayLogins`:
    /// those turns run in the bot's own gateway, which loads only its own copy); 0.9.18 the first that makes that bot name
    /// the site for a login or a code (`namedSites`: the check runs in each bot's own copy); 0.9.19 the first that gives
    /// that bot the Device Access tools (`deviceAccess`: each bot's own copy registers them); 0.9.21 the first with the
    /// tools for every kind besides Contacts (`deviceAccessKinds`); 0.9.22 the first that pushes that bot's steps to a
    /// reply's Lock Screen card (`liveSteps`: the step hook runs in each bot's own copy); 0.9.23 the first whose steps
    /// leave iOS's ration of urgent card pushes to the turn's end (`liveEnds`: the end goes from each bot's own copy too);
    /// 0.9.24 the first that takes a quick reply's Done card away after a minute (`liveQuick`: that end is each bot's too);
    /// 0.9.32 the first that gives that bot the task tools (`tasks`: each bot's own copy registers `hq_tasks`, so a chat
    /// with it can add to the shared list); 0.9.42 the first that keeps a scheduled job's pictures in that bot's Bot Chat
    /// summary (`cronMedia`: the summary is saved through each bot's own copy); 0.9.44 the first whose login or code card
    /// names the site that bot named, not another site's tab left open (`namedTabs`: the tab is picked in each bot's
    /// own copy); 0.9.45 the first whose daily Task ideas run is let in (`ideasRun`: the ideas bot is any bot); 0.9.47
    /// the first that gives that bot `draft_message` (`draftCards`: each bot's own copy registers the tool and its guard);
    /// 0.9.50 the first whose dashboard-tile skill draws a tile from the bot's data with a kit (`tileFit`: a bot reads
    /// the skill from its own copy, so a bot with an older one still writes the page itself; a tester's status boards
    /// came out cut off and crowded, 2026-11-11); 0.9.54 the first whose alert for a helper's approval or question opens
    /// the chat that started the helper (`helperAlerts`: the alert goes from each bot's own copy).
    static let everyBotVersion = "0.9.54"

    /// [addon-reminder] The add-on version whose flags `current` checks: raise it with every flag added there. The
    /// launch alert offers an update once per `offerLevel`; after Not Now the app only reminds quietly (AddOnReminder)
    /// until a build asks for a newer level. 0.9.25: `terminal` (the main bot's copy serves it; no bot needs its own).
    /// 0.9.32: `tasks` (the shared task list and its routes). 0.9.42: `cronMedia` (a job's pictures in Bot Chat summaries).
    /// 0.9.44: `namedTabs` (a login or code card names the site the bot is signing in to). 0.9.45: `ideasRun` (the daily
    /// Task ideas run saves its ideas again). 0.9.47: `draftCards` (a bot's draft for review as a card). 0.9.52:
    /// `pluginUpdates` (the main bot's copy serves it, so a plugin update that adds Python packages finishes in the app;
    /// no bot needs its own for that). 0.9.53: `task_fields` (a task's priority, tags, alert, start day and files).
    /// 0.9.54: `helperAlerts` (a helper's approval alert opens the chat with the card).
    static let wantedVersion = "0.9.54"
    static let offerLevel = "\(wantedVersion)/\(everyBotVersion)"
    static let pluginName = "hermes-hq-push"

    /// A bot's own add-ons (plugins.manage list for its profile) hold hermes-hq-push, turned on, at least `minimum`.
    static func botHasPlugin(_ plugins: [PluginInfo], minimum: String = everyBotVersion) -> Bool {
        plugins.contains { $0.name == pluginName && $0.enabled && versionAtLeast($0.version, minimum) }
    }

    /// [load-cache] The same rule over a list kept by PluginListCache.
    static func botHasPlugin(_ kept: PluginListCache.Entry, minimum: String = everyBotVersion) -> Bool {
        kept.plugins.contains { $0.name == pluginName && $0.enabled && versionAtLeast($0.version, minimum) }
    }

    /// "0.9.12" ≥ "0.9.9" (numbers, not text); a missing part counts as 0 and an unreadable version as too old.
    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
            return pieces.isEmpty || pieces.contains(nil) ? nil : pieces.compactMap { $0 }
        }
        guard let have = parts(version), let need = parts(minimum) else { return false }
        for index in 0..<max(have.count, need.count) {
            let a = index < have.count ? have[index] : 0, b = index < need.count ? need[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    static let route = "/api/plugins/hermes-hq-push"
    static let legacyRoute = "/api/plugins/dispatch-push"
    /// The route this account's plugin last answered on first, then the other.
    static func routes(preferring cached: String?) -> [String] {
        cached == legacyRoute ? [legacyRoute, route] : [route, legacyRoute]
    }

    enum PluginState: String, Sendable { case ready, outdated, missing, unknown }
    /// "missing" (404 on both names), "outdated" (an old dispatch-push, or one too old to seal, watch every bot or own chats),
    /// "ready", or "unknown" (no answer).
    static func pluginState(status: Int, body: [String: Any]?, legacy: Bool) -> PluginState {
        status == 404 ? .missing : status != 200 ? .unknown : legacy || !current(body) ? .outdated : .ready
    }

    /// An alert iOS showed still sealed read only "New notification": Approve there would run a command nobody saw.
    static func mayAnswer(_ action: String, delivered: [AnyHashable: Any]) -> Bool { action != "approve" || delivered["seal"] == nil }

    /// A request id the approval route takes.
    static func validRequest(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
}

/// Approve/Deny taps from pushed alerts, kept until their account is signed in, sent once, given up after ten minutes.
/// First tap wins; the last 64 settled ids stay. (UserDefaults `hermes.push.answers`.)
nonisolated struct PushAnswers: Codable, Equatable, Sendable {
    struct Answer: Codable, Equatable, Sendable {
        let request: String, sessionKey: String, token: String, session: String, choice: String, owner: String
        let tappedAt: Date
        /// What a failure alert about it names (UX study #260): the bot, the command its alert showed, the bot's
        /// profile. Absent in answers saved by an older build.
        var who: String? = nil, command: String? = nil, profile: String? = nil
    }
    enum Outcome: String, Sendable { case queued, answered, failed, expired, stale, waiting, send, duplicate }
    private(set) var pending: [Answer] = []
    private(set) var answered: [String] = []

    static func decode(_ data: Data?) -> Self { data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }

    mutating func enqueue(_ answer: Answer) -> Outcome {
        guard !answered.contains(answer.request), !pending.contains(where: { $0.request == answer.request }) else { return .duplicate }
        pending.append(answer); return .queued
    }
    mutating func decision(_ answer: Answer, owner: String?, ready: Bool, now: Date) -> Outcome {
        if now.timeIntervalSince(answer.tappedAt) >= 600 { settle(answer.request); return .expired }
        if let owner, owner != answer.owner { settle(answer.request); return .stale }
        return ready && owner == answer.owner ? .send : .waiting
    }
    mutating func drop(owner: String) {
        for answer in pending where answer.owner == owner { settle(answer.request) }
    }
    mutating func settle(_ request: String) {
        pending.removeAll { $0.request == request }
        if !answered.contains(request) { answered.append(request) }
        answered = Array(answered.suffix(64))
    }
    mutating func result(_ answer: Answer, status: Int, resolved: Int?) -> Outcome {
        guard status != 0 else { return .waiting }
        settle(answer.request)
        return status == 200 && (resolved ?? 0) >= 1 ? .answered : .failed
    }
}

/// Which account's gateway holds this device's registration, and which accounts still owe a removal. It outlives
/// sign-out so a removal is retried when that account is back. (UserDefaults `hermes.push.ledger`.)
nonisolated struct PushLedger: Codable, Equatable, Sendable {
    private(set) var owner: String?
    /// The account whose registration PUT went out unconfirmed (no answer).
    private(set) var candidate: String?
    private(set) var unknown = false
    private(set) var owed: [String] = []
    private(set) var kinds: Set<String> = []

    static func decode(_ data: Data?, legacy: Bool = false) -> Self {
        if let data, let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        var value = Self(); value.unknown = legacy; return value
    }
    mutating func owe(_ owner: String) {
        if !owed.contains(owner) { owed.append(owner) }
        owed = Array(owed.suffix(4))
    }
    mutating func switchTo(_ next: String) {
        if let owner, owner != next { owe(owner); self.owner = nil; kinds = [] }
        if candidate != next { candidate = nil }
    }
    mutating func adopt(_ account: String) {
        if unknown { owe(account); unknown = false }
    }
    func needsRemoval(_ account: String) -> Bool { unknown || owner == account || owed.contains(account) }
    mutating func attempt(_ account: String) {
        switchTo(account); owe(account); candidate = account
    }
    mutating func registered(_ account: String, kinds: Set<String>) {
        switchTo(account); owner = account; candidate = nil; unknown = false; self.kinds = kinds; owed.removeAll { $0 == account }
    }
    mutating func advertised(_ kinds: Set<String>) { self.kinds.formIntersection(kinds) }
    mutating func removal(_ account: String, status: Int) {
        if [200, 204, 404].contains(status) {
            owed.removeAll { $0 == account }; unknown = false
            if owner == account { owner = nil }
            if candidate == account { candidate = nil }
        } else { owe(account) }
        if owner == nil || owner == account { kinds = [] }
    }
    mutating func unavailable() { kinds = [] }
    mutating func clear() {
        if let owner { owe(owner) }
        if let candidate { owe(candidate) }
        owner = nil; candidate = nil; kinds = []
    }
    /// The account a pushed alert came from, which its answer may go to (nil: none here may answer it).
    func sender(_ tag: String?) -> String? {
        guard let holder = owner ?? candidate else { return nil }
        if let tag { return tag == holder ? holder : nil }
        return unknown || owed.contains(where: { $0 != holder }) ? nil : holder
    }
}
