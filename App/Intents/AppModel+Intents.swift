// The app model's side of Siri, Shortcuts and the quick actions (docs/spec/3x-intents.md §3.5, §4, §9.1, §9.2, §11):
// which account is signed in (its digest and sign-in epoch), the bots the system's pickers list, the targets of the
// Home Screen items, and what goes at sign-out. `AppModel` calls in from six tagged one-liners.

import AppIntents
import UIKit
import os

extension AppModel {
    /// The signed-in account as the web app wrote it: `url + "\n" + username` (§3.2).
    var intentsAccount: String? {
        guard let account else { return nil }
        let stored = signIn.store.stored(account)
        return VoiceBotCatalog.account(url: stored?.url ?? account.baseURL.absoluteString, username: stored?.username ?? account.username ?? "")
    }

    /// The account was activated (every launch, a fresh sign-in, a gateway switch).
    func intentsDidActivate(_ account: GatewayAccount) {
        let stored = signIn.store.stored(account)
        let url = stored?.url ?? account.baseURL.absoluteString, username = stored?.username ?? account.username ?? ""
        let wiring = IntentsWiring.shared
        wiring.install(self)
        switch ShortcutPolicy.activate(url: url, username: username) {
        case .same: break
        case .first:
            // No sign-in was on record: nothing of another account's can be here but Home Screen items.
            QuickActions.resetItems()
        case .changed:
            // DECISION I14: another account's requests, bots and Home Screen items go. A saved older-build note stays
            // (never lose audio).
            QuickActions.resetItems()
            IntentsRuntime.shared.reset()
            wiring.catalog.empty()
            wiring.visits = [:]
            AppLog.note("intents", "account changed")
        }
        // Bots stored for another account (an update from a build that did not keep the digest) are not this one's.
        if let first = VoiceBotCatalog.bots().first, !VoiceBotCatalog.sameAccount(first.account, VoiceBotCatalog.account(url: url, username: username)) {
            wiring.catalog.empty()
        }
        intentsListsChanged()
        IntentsRuntime.shared.kick()                 // a request that launched the app
    }

    /// The roster or the Sessions list changed.
    func intentsListsChanged() {
        let wiring = IntentsWiring.shared
        let interval = wiring.signposts.beginInterval("intents lists")
        defer { wiring.signposts.endInterval("intents lists", interval) }
        // DECISION I4: an empty roster is written only once the gateway has answered with one (never while it loads, never
        // after a failed read).
        wiring.catalog.sync(bots: bots, account: intentsAccount, answered: (botStore?.phase ?? .none) >= .slim)
        QuickActions.schedule()
    }

    /// A chat's open applied: it is the most recent target of the Home Screen items.
    func intentsVisited(_ chat: LiveChatSession) {
        let id: String
        if chat.menus.isBotChat {
            id = "bot:" + VoiceBotCatalog.key(profile: chat.profile)
        } else if let stored = chat.storedSessionId ?? chat.resolvedStoredId {
            id = "session:" + stored
        } else {
            return
        }
        IntentsWiring.shared.visits[id] = Date().timeIntervalSince1970
        IntentsEvents.note("visited " + id)
        QuickActions.schedule()
    }

    /// Sign-out (DECISION I14): requests, the pickers' bots, the Home Screen items with their account and epoch, and the
    /// saved older-build note with its file.
    func intentsSignedOut() {
        let wiring = IntentsWiring.shared
        IntentsRuntime.shared.reset()
        wiring.catalog.empty()
        wiring.visits = [:]
        if let note = VoiceBotCatalog.pendingNote() {
            if let file = LegacyNoteFile.resolve(note.path) { LegacyNoteFile.remove(file) }
            VoiceBotCatalog.clearPendingNote()
        }
        QuickActions.clear()
        IntentsEvents.note("signed out")
        AppLog.note("intents", "signed out")
    }

    /// The targets of the Home Screen items as the lists are now; nil while there is nothing to go by (signed out, or
    /// lists that never loaded).
    fileprivate var intentsTargets: [ShortcutTarget]? {
        guard account != nil else { return nil }
        let bots = bots, sessions = sessions
        if bots.isEmpty, sessions.isEmpty, (botStore?.phase ?? .none) < .slim { return nil }
        // UX study #265: group chats too (DECISION I7 waited only for them to exist), by their last message.
        let rooms = groupStore?.rooms ?? []
        let extra = rooms.map { ShortcutTarget(id: "room:" + $0.key, name: $0.name, kind: "room", group: $0.key) }
        var activity: [String: Double] = [:]
        for room in rooms { if let last = room.log.last { activity["room:" + room.key] = last.at / 1000 } }
        return ShortcutCatalogBuilder.targets(bots: bots, sessions: sessions, visits: IntentsWiring.shared.visits,
                                              extra: extra, extraActivity: activity)
    }

    /// A donated conversation the system handed back (§10.3): the path a tapped alert takes.
    func continueConversation(_ stored: String) {
        guard NotificationRules.valid(stored) else { return }
        AppLog.note("intents", "continue conversation")
        IntentsEvents.note("continue " + stored)
        NotificationHub.shared.queueOpen(stored, profile: nil)
    }
}

/// What the app model's intents calls keep between them (an extension cannot hold stored properties).
@MainActor final class IntentsWiring {
    static let shared = IntentsWiring()
    let catalog = IntentsCatalogSync()
    /// When each quick-action target was last opened in this run (seconds since 1970, by target id).
    var visits: [String: Double] = [:]
    /// Instruments › os_signpost "intents lists": the cost of one list change on the main thread (S3).
    let signposts = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "HermesHQ", category: "intents")
    private var host: LiveIntentsHost?
    private var activeObserver: (any NSObjectProtocol)?
    private weak var model: AppModel?

    /// Called as the scene connects and again at every account activation: once per app model.
    func install(_ model: AppModel) {
        guard self.model !== model || host == nil else { return }
        self.model = model
        let host = LiveIntentsHost(model: model)
        self.host = host
        IntentsRuntime.shared.host = host
        // The scene's own callback can come before the app counts as active (build 240 guarded the same,
        // W:ios/App/App/VoiceNoteIntent.swift): this one comes when it does.
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { IntentsRuntime.shared.kick() }
            }
        }
        QuickActions.rows = { [weak model] in model?.intentsTargets }
    }
}

/// Keeps the pickers' stored bots equal to the roster, and tells the system when they changed (§4).
@MainActor final class IntentsCatalogSync {
    private let defaults: UserDefaults
    /// The least time between two parameter refreshes (the last change always gets its call).
    private let interval: TimeInterval
    private let refresh: () -> Void
    private(set) var writes = 0
    private(set) var refreshes = 0
    private var lastRefresh: Date?
    private var waiting = false
    /// The roster last synced (ids and names, hashed): an unchanged roster costs one pass and no encoding.
    private var lastRoster: Int?

    init(defaults: UserDefaults = .standard, interval: TimeInterval = 1,
         refresh: @escaping () -> Void = { IntentsCatalogSync.tellTheSystem() }) {
        self.defaults = defaults
        self.interval = interval
        self.refresh = refresh
    }

    /// Returns whether the stored catalog changed. `answered`: the gateway has answered with a roster in this run.
    @discardableResult func sync(bots: [Bot], account: String?, answered: Bool) -> Bool {
        guard let account else { return false }
        if bots.isEmpty, !answered { return false }
        var hasher = Hasher()
        hasher.combine(account)
        for bot in bots { hasher.combine(bot.id); hasher.combine(bot.name) }
        let roster = hasher.finalize()
        if roster == lastRoster { return false }
        lastRoster = roster
        let records = ShortcutCatalogBuilder.botRecords(bots: bots, account: account)
        // The roster is ordered by activity, so its order changes whenever another bot becomes the newest. For the
        // pickers that is no change: the stored bots stay as they are, and the system is not told. (It rations these
        // calls: seen in the simulator's log, "Donation quota exceeded", after which a real rename did not reach the
        // Shortcuts app. Each call must be worth it.)
        let stored = VoiceBotCatalog.bots(defaults)
        if !stored.isEmpty, stored.count == records.count {
            let order: (VoiceBotRecord, VoiceBotRecord) -> Bool = { $0.id < $1.id }
            if stored.sorted(by: order) == records.sorted(by: order) { return false }
        }
        guard VoiceBotCatalog.store(records, defaults) else { return false }
        changed(records.count)
        return true
    }

    /// Sign-out or another account: the pickers list nothing.
    func empty() {
        lastRoster = nil
        guard defaults.object(forKey: VoiceBotCatalog.botsKey) != nil else { return }
        VoiceBotCatalog.clear(defaults)
        changed(0)
    }

    private func changed(_ count: Int) {
        writes += 1
        AppLog.note("intents", "shortcut bots: \(count)")
        IntentsEvents.note("catalog \(count)")
        let now = Date()
        if let last = lastRefresh, now.timeIntervalSince(last) < interval {
            guard !waiting else { return }
            waiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - now.timeIntervalSince(last))) { [weak self] in
                self?.waiting = false
                self?.fire()
            }
            return
        }
        fire()
    }

    /// The system re-reads the pickers' bots. iOS rations these calls per app (`linkd`: "Donation quota exceeded",
    /// about five in a few minutes on the simulator) and drops the ones over it.
    static func tellTheSystem() {
        #if DEBUG
        // A UI test run signs in afresh for every test and would spend the ration in its first minute: only the test
        // that looks in the Shortcuts app makes the real call (`-HQDebugQuietShortcutParameters YES` for the others).
        if UserDefaults.standard.bool(forKey: "HQDebugQuietShortcutParameters") { return }
        #endif
        HQAppShortcuts.updateAppShortcutParameters()
    }

    private func fire() {
        lastRefresh = Date()
        refreshes += 1
        refresh()
        IntentsEvents.note("parameters refreshed")
    }
}

/// What a cold launch was asked to open (§9.4, §10.3), for the scene.
@MainActor enum IntentsLaunch {
    /// The launch came to open something of ours: the last chat is not reopened over it.
    static func claims(_ options: UIScene.ConnectionOptions) -> Bool {
        if options.userActivities.contains(where: { IntentsRouting.conversation($0.interaction) != nil }) { return true }
        // Only a request: a saved older-build note is no reason to skip the last chat (one that cannot be brought in,
        // another account's, would switch the reopening off for good). Its recovery opens the bot's chat itself.
        if VoiceNoteRequestStore(defaults: .standard).pending != nil { return true }
        #if DEBUG
        if IntentsDebugHooks.claimsLaunch { return true }
        #endif
        return false
    }

    /// The scene connected: a quick action or a donated conversation that launched the app goes where a warm one goes.
    static func connected(_ options: UIScene.ConnectionOptions, model: AppModel) {
        // The runtime needs the app before the saved sign-in is restored: a quick action that launched the app waits
        // (≤ 10 s) for the tabs, it is not dropped.
        IntentsWiring.shared.install(model)
        if let item = options.shortcutItem { _ = QuickActions.perform(item) }
        if let id = options.userActivities.lazy.compactMap({ IntentsRouting.conversation($0.interaction) }).first {
            model.continueConversation(id)
        }
        #if DEBUG
        IntentsDebugHooks.sceneConnected(model: model)
        #endif
    }
}

extension NotificationHub {
    /// §10.2 (DECISION I13): a local alert about a known chat donates its conversation — the same sender, face, chat
    /// name and conversation id as the alert, and no message text. Not waited for; the alert posts either way.
    /// `face`: the bot's round face as the alert carries it (made once, in `post`).
    func donateConversation(kind: String, entry: Entry?, subtitle: String, stored: String, face: Data?) {
        guard kind != "test", let entry else { return }
        let who = NotificationText.sanitized(entry.who)
        guard let interaction = PushFaces.donation(sender: who.sender, handle: entry.profile, face: face,
                                                   chat: !who.group.isEmpty ? who.group : subtitle, conversation: stored) else { return }
        interaction.donate { error in
            let code = (error as NSError?)?.code
            Task { @MainActor in
                AppLog.note("notify", code.map { "donation failed \($0)" } ?? "donated")
                IntentsEvents.note("donation " + stored + " " + (code.map { "error \($0)" } ?? "ok"))
            }
        }
    }
}
