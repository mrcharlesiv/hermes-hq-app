// Home Screen quick actions: press and hold the app's icon (docs/spec/3x-intents.md §9; a port of build 240's
// `DispatchShortcuts`, W:ios/App/App/HermesUIPages.swift:218-276, where they were switched off). "New memo to <bot>",
// "Open <chat>" for the two most recent, "Search Chats". Every item carries the sign-in epoch: one captured before a
// sign-out or a gateway switch is refused.

import UIKit

@MainActor enum QuickActions {
    /// DECISION I5: on. When false the app shows none, as build 240 did.
    nonisolated static let enabled = true
    nonisolated static let typePrefix = "dispatch."

    /// What the stored catalog shows on the Home Screen. Pure (the tests read it).
    nonisolated static func plan(_ safe: [ShortcutTarget], enabled: Bool = QuickActions.enabled) -> [Planned] {
        guard enabled, !safe.isEmpty else { return [] }                 // never a lone "Search Chats"
        var items: [Planned] = []
        if let bot = safe.first(where: { $0.kind == "bot" }) {
            items.append(Planned(action: "memo", title: IntentsText.newMemo(bot.name), symbol: "mic", id: bot.id))
        }
        for target in safe.prefix(2) {
            items.append(Planned(action: "open", title: IntentsText.open(target.name), symbol: target.kind == "room" ? "person.2" : "bubble.left",
                                 id: target.id))
        }
        items.append(Planned(action: "search", title: IntentsText.searchChats, symbol: "magnifyingglass", id: nil))
        return items
    }

    nonisolated struct Planned: Equatable, Sendable {
        let action: String
        let title: String
        let symbol: String
        /// The target's id (with its epoch in front); nil for Search Chats.
        let id: String?
        var type: String { QuickActions.typePrefix + action }
    }

    /// The items on the Home Screen now, as the DEBUG state file and the tests read them.
    static var shown: [Planned] = []

    // MARK: Keeping the items current

    private static var timer: Timer?
    /// The lists as they are now (the app model sets it); nil while there is nothing to go by.
    static var rows: (() -> [ShortcutTarget]?)?

    /// A list changed or a chat was opened: rebuild half a second later (changes come in bursts).
    static func schedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in
                timer = nil
                if let rows = rows?() ?? nil { update(rows) }
            }
        }
    }

    /// Port of `DispatchShortcuts.update`: binds the targets to the sign-in epoch, stores them, sets the items.
    static func update(_ rows: [ShortcutTarget], defaults: UserDefaults = .standard) {
        guard ShortcutPolicy.digest(defaults) != nil, let epoch = ShortcutPolicy.epoch(defaults) else { return }
        let safe = ShortcutPolicy.catalog(rows, epoch: epoch, validSession: NotificationRules.valid)
        if let data = ShortcutPolicy.encoded(safe, defaults) {
            defaults.set(data, forKey: ShortcutPolicy.catalogKey)
        } else if ShortcutPolicy.targets(defaults) != safe {
            return                                                       // over the size limit: keep what is stored
        }
        apply(plan(safe), epoch: epoch)
    }

    private static func apply(_ items: [Planned], epoch: String) {
        #if targetEnvironment(macCatalyst)
        // [mac] The Dock menu reads `shown` (MacDockMenu); the system's own items are never set, so none show twice.
        guard items != shown else { return }
        shown = items
        #else
        guard items != shown || UIApplication.shared.shortcutItems?.count != items.count else { return }
        shown = items
        UIApplication.shared.shortcutItems = items.map { item in
            UIApplicationShortcutItem(type: item.type, localizedTitle: item.title, localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: item.symbol),
                                      userInfo: item.id.map { ["id": $0 as NSString, "epoch": epoch as NSString] })
        }
        #endif
        AppLog.note("intents", "quick actions: \(items.count)")
        IntentsEvents.note("quick actions \(items.count)")
    }

    /// Another account's items leave the Home Screen (its catalog, digest and epoch were already replaced).
    static func resetItems() {
        timer?.invalidate()
        timer = nil
        shown = []
        UIApplication.shared.shortcutItems = []
        IntentsEvents.note("quick actions 0")
    }

    /// Sign-out or another account: the catalog, the account and its epoch go, and the Home Screen shows none.
    static func clear(defaults: UserDefaults = .standard) {
        timer?.invalidate()
        timer = nil
        ShortcutPolicy.clear(defaults)
        shown = []
        UIApplication.shared.shortcutItems = []
        IntentsEvents.note("quick actions 0")
    }

    // MARK: Performing one (§9.4)

    /// A Home Screen item was chosen. False (and nothing on screen) for anything that is not ours or not from this
    /// sign-in.
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type.hasPrefix(typePrefix) else { return false }
        return perform(action: String(item.type.dropFirst(typePrefix.count)), id: item.userInfo?["id"] as? String ?? "",
                       epoch: item.userInfo?["epoch"] as? String)
    }

    static func perform(action: String, id: String, epoch: String?, defaults: UserDefaults = .standard) -> Bool {
        let current = ShortcutPolicy.epoch(defaults)
        guard enabled, ShortcutPolicy.permits(action, id: id, epoch: epoch, current: current, targets: ShortcutPolicy.targets(defaults)),
              let current else {
            IntentsEvents.note("quick action refused " + action)
            return false
        }
        IntentsEvents.note("quick action " + action)
        Task { await IntentsRuntime.shared.route(action, id: id, epoch: current) }
        return true
    }

    /// "Open Bot" (the legacy intent): its id is a quick-action bot id. The quick-action catalog holds the 128 most
    /// recent targets and is written half a second after a change, so a bot it does not hold yet is looked up in the
    /// pickers' catalog, under the same epoch and account rule.
    static func openBot(legacyId id: String, defaults: UserDefaults = .standard) -> Bool {
        if perform(action: "open", id: id, epoch: nil, defaults: defaults) { return true }
        guard let epoch = ShortcutPolicy.epoch(defaults), let bot = ShortcutPolicy.legacyBot(id: id, defaults) else { return false }
        IntentsEvents.note("open bot " + (VoiceBotCatalog.profile(key: bot.key) ?? bot.key))
        let target = ShortcutTarget(id: id, name: bot.name, kind: "bot", botKey: bot.key)
        Task { await IntentsRuntime.shared.route("open", id: id, epoch: epoch, fallback: target) }
        return true
    }
}
