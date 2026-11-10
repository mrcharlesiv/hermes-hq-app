// Per-bot Mute on this iPhone (port of the web app's src/ui-bots/bot-mute.ts, info-state.ts `muteValue` and
// HermesUIBots.swift `DispatchBotMute`, build 240). A mute silences a bot's finished-reply alerts (local alerts, the reply
// peek and, through the notification extension, sealed pushes); approval requests, questions and failures still notify.
// Stored on this device only, by gateway account (PushPolicy.owner, the `account` a push names) and profile. Compiled into
// the app and the notification extension: the list lives in the Keychain group the two already share (the extension's
// App Store profile carries no App Group), readable after first unlock, never synced. Never logs.

import Foundation
import Security

nonisolated struct BotMute: Codable, Equatable, Sendable {
    var always: Bool
    /// When a timed mute ends (nil for Always).
    var until: Date?

    static let forever = BotMute(always: true, until: nil)

    func live(_ now: Date = Date()) -> Bool { always || (until.map { $0 > now } ?? false) }
}

/// Mute Notifications' choices in Bot Info (`MUTE_CHOICES`). Menus and swipes use Always.
nonisolated enum MuteChoice: String, CaseIterable, Sendable {
    case off, hour, hours8, week, always

    var title: String {
        switch self {
        case .off: "Off"
        case .hour: "For 1 Hour"
        case .hours8: "For 8 Hours"
        case .week: "For 1 Week"
        case .always: "Always"
        }
    }

    /// The mute this choice makes from `now` (nil: Off).
    func mute(from now: Date = Date()) -> BotMute? {
        switch self {
        case .off: nil
        case .hour: BotMute(always: false, until: now.addingTimeInterval(3600))
        case .hours8: BotMute(always: false, until: now.addingTimeInterval(8 * 3600))
        case .week: BotMute(always: false, until: now.addingTimeInterval(168 * 3600))
        case .always: .forever
        }
    }
}

nonisolated enum BotMutes {
    /// What a mute covers, as Bot Info's footer and the first mute's tip say it.
    static var scope: String { "Only on this \(DeviceWord.name). Approval requests still notify you." }   // [m9/ipad]
    /// The finished-reply kinds a mute silences (local kinds, the push plugin's `turnDone`, background work).
    static let silenced: Set<String> = ["message.complete", "turnDone", "backgroundDone"]
    /// At most this many mutes are kept (the web's native list cap).
    static let limit = 512

    static func key(account: String, profile: String) -> String {
        account + "\n" + profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The live mute for a key (an ended one reads as none).
    static func mute(_ mutes: [String: BotMute], _ key: String, now: Date = Date()) -> BotMute? {
        guard let mute = mutes[key], mute.live(now) else { return nil }
        return mute
    }

    /// Which choice Info's list checks: Off or Always; a timed mute checks none (its value says when it ends).
    static func choice(_ mute: BotMute?, now: Date = Date()) -> MuteChoice? {
        guard let mute, mute.live(now) else { return .off }
        return mute.always ? .always : nil
    }

    /// "Off", "Always", "Until 6:30 PM" (within 20 hours), "Until Tue, Oct 6": Mute Notifications' value.
    static func value(_ mute: BotMute?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let mute, mute.live(now) else { return "Off" }
        guard !mute.always, let until = mute.until else { return "Always" }
        var style: Date.FormatStyle
        if until.timeIntervalSince(now) < 20 * 3600 {
            style = Date.FormatStyle(date: .omitted, time: .shortened)
        } else {
            style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        }
        style.locale = locale
        style.timeZone = timeZone
        return "Until " + until.formatted(style)
    }

    /// Whether an alert of `kind` from `profile` (on `account`) may show: false only for a finished reply from a muted bot.
    static func allows(kind: String, account: String, profile: String, mutes: [String: BotMute], now: Date = Date()) -> Bool {
        guard silenced.contains(kind), !account.isEmpty, !profile.isEmpty else { return true }
        return mute(mutes, key(account: account, profile: profile), now: now) == nil
    }

    /// A pushed alert's own kind (`dispatch.kind`: "turnDone", "approval", or one a later plugin adds) as the filter reads it.
    static func pushKind(_ remote: [String: Any]) -> String { remote["kind"] as? String ?? "" }

    /// Only live mutes, newest-ending kept when over the cap.
    static func pruned(_ mutes: [String: BotMute], now: Date = Date()) -> [String: BotMute] {
        let live = mutes.filter { $0.value.live(now) }
        guard live.count > limit else { return live }
        let kept = live.sorted { ($0.value.always ? Date.distantFuture : $0.value.until ?? .distantPast)
            > ($1.value.always ? Date.distantFuture : $1.value.until ?? .distantPast) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// When the soonest timed mute ends (rows lose their bell then).
    static func nextExpiry(_ mutes: [String: BotMute], now: Date = Date()) -> Date? {
        mutes.values.filter { !$0.always && $0.live(now) }.compactMap(\.until).min()
    }

    static func encode(_ mutes: [String: BotMute]) -> Data? { try? JSONEncoder().encode(mutes) }
    static func decode(_ data: Data?) -> [String: BotMute] {
        data.flatMap { try? JSONDecoder().decode([String: BotMute].self, from: $0) } ?? [:]
    }

    /// The list as the app and the extension read it.
    static func stored(now: Date = Date()) -> [String: BotMute] { pruned(decode(BotMuteKeychain.read()), now: now) }
}

/// The mute list in the Keychain group the app and its notification extension share (as PushFaces and PushSealKeys).
nonisolated enum BotMuteKeychain {
    static let service = "ai.hermes.hq.bot-mutes"
    static let account = "mutes"
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the list (nil or empty data removes it). Returns whether the Keychain holds what was asked.
    @discardableResult static func write(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(item as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        if SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
