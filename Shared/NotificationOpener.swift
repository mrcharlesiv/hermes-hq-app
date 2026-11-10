// What the notification extension does with one push (port of the web app's NotificationService.didReceive, build 240),
// as a pure function the app's unit tests run with their own keys, faces and counters (`simctl push` never runs an
// extension). Opens a sealed alert: its real words, its chat's stack, its order, its category (Approve/Deny) and the
// plugin's `dispatch` fields; then the bot's face. Anything that can't be opened shows as "New notification" with no
// Approve (nobody saw the command).

import Foundation
import UserNotifications

nonisolated enum NotificationOpener {
    struct Environment {
        var keys: () -> [Data]
        var face: (_ account: String, _ profile: String) -> Data?
        var locked: () -> Bool
        var record: (String) -> Void
        /// The mutes set on this iPhone (Shared/BotMutes.swift), read once per push.
        var mutes: () -> [String: BotMute] = { [:] }

        static var live: Environment {
            Environment(keys: { PushSealKeys.all() }, face: { PushFaces.face(account: $0, profile: $1) },
                        locked: { PushSealKeys.locked() }, record: { PushAlertDiagnostics.record($0) },
                        mutes: { BotMutes.stored() })
        }
    }

    /// The content iOS should show for `content` (as it arrived).
    static func process(_ content: UNNotificationContent, environment env: Environment) -> UNNotificationContent {
        guard content.userInfo["seal"] != nil else { env.record("plain"); return content }
        let keys = env.keys()
        guard let inner = PushSeal.open(content.userInfo, keys: keys), let alert = PushSeal.alert(inner),
              let opened = content.mutableCopy() as? UNMutableNotificationContent else {
            env.record(env.locked() ? "locked" : PushSeal.failure(content.userInfo, keys: keys))
            return unopened(content)
        }
        opened.title = alert.title
        opened.subtitle = alert.subtitle
        opened.body = alert.body
        opened.threadIdentifier = alert.thread
        opened.categoryIdentifier = alert.category
        if let relevance = alert.relevance { opened.relevanceScore = relevance }
        var info = content.userInfo
        info["seal"] = nil
        for (key, value) in inner { info[key] = value }
        opened.userInfo = info
        let remote = inner["dispatch"] as? [String: Any] ?? [:]
        let account = remote["account"] as? String ?? "", profile = remote["profile"] as? String ?? ""
        let face = env.face(account, profile)
        env.record(face == nil && !profile.isEmpty ? "noFace" : "opened")
        let shown = PushFaces.message(opened, sender: alert.title, profile: profile, face: face, chat: alert.subtitle,
                                      conversation: remote["session"] as? String ?? "")
        // A muted bot's finished reply (Bot Info › Mute Notifications): an extension can't drop an alert without
        // Apple's filtering entitlement, so it arrives quietly in Notification Center (no sound, no banner, no wake), as
        // a muted Messages conversation does. Approvals and every other kind keep their alert.
        guard !BotMutes.allows(kind: BotMutes.pushKind(remote), account: account, profile: profile, mutes: env.mutes()) else { return shown }
        return quieted(shown)
    }

    /// The same alert, delivered without sound, banner or screen wake.
    static func quieted(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.sound = nil
        copy.interruptionLevel = .passive
        copy.relevanceScore = 0
        return copy
    }

    /// An alert that couldn't be opened says only "New notification", so it offers no Approve. A plugin from before the
    /// rename (dispatch-push) seals under the old name: its placeholder says "Hermes HQ" too.
    static func unopened(_ content: UNNotificationContent) -> UNNotificationContent {
        let renamed = content.title == "Dispatch"
        guard renamed || !content.categoryIdentifier.isEmpty, let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.categoryIdentifier = ""
        if renamed { copy.title = "Hermes HQ" }
        return copy
    }

    /// iOS's time ran out before the work finished: a sealed alert shows as unopened, a plain one as it came.
    static func expired(_ original: UNNotificationContent, record: (String) -> Void) -> UNNotificationContent {
        record("expired")
        return original.userInfo["seal"] != nil ? unopened(original) : original
    }
}
