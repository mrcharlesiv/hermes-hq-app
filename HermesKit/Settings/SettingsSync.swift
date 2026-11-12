// [sync] The app's settings follow the owner from device to device (owner 2026-11-03: "a lot of things are not carrying
// over from the mobile app to the desktop app"). A setting is a UserDefaults value on the list below; each one carries
// the time it was last set, so a theme changed on the Mac and a prompt saved on the iPhone at the same moment both
// survive (the newer of each setting wins, not the newer of the whole list). Two documents on the gateway
// (`GatewaySync`): "settings" (the switches and choices) and "library" (saved Prompts and Word Fixes, the big ones).
//
// What stays on each device: its text size (UI Scale), pane and sidebar widths, the tab bar (the iPhone's holds four,
// the Mac's sidebar every page), backgrounds (their pictures are files here), notification choices, haptics, and every
// sign-in (Keychain, never UserDefaults; a key that even sounds like a credential is refused).
// A setting added later travels once it is listed here.

import Foundation

nonisolated enum SyncedSettingKeys {
    /// Settings by their exact key.
    static let settings: Set<String> = [
        // Appearance and Theme
        "hqn.appearance", "hqn.theme.skin", "hqn.theme.chosen", "hqn.theme.desktopLook", "hqn.theme.skinBeforeLook",
        "hqn.theme.highContrast", "hqn.theme.bubbleCorners", "hqn.theme.bubbleStyle", "hqn.theme.glassBubbles", "hqn.theme.topEdge",
        "hqn.theme.desktopCorners", "hqn.theme.desktopComposer", "hqn.theme.messageColour",
        "hqn.head.style",
        // Chat
        "hqn.inAppTips", "hqn.introSplash", "hqn.fileBrowser", "hqn.attachmentLimitMb", "hqn.reactions", "hqn.reactions.touched",
        "hq.chat.toolCallStyle", "hq.chat.toolCallsAfterReply", "hq.chat.fewerTimestamps", "hq.chat.showFileChanges", "hqn.thinkingDrive",
        "hqn.newChatKeyBot", "hqn.newChatKeyMode", "hqn.newChatKeyProject", "hqn.newChatAsksProject", "hqn.sendWhileBusy",
        // Sounds
        "hqn.completionSoundOn", "hqn.completionSoundVariant",
        // Voice
        "hq.voice.sendOnRelease", "hq.voice.readRepliesAloud", "hq.voice.engine", "hq.voice.replyVoice", "hq.voice.memoSpeed",
        "hq.voice.liveWords",
        // Tiles and pages
        "hq.artifactPins.view", "hq.artifactPins.gridNames", "pages.more.starmap.view", "capabilities.tools.sort",
    ]

    /// The big lists, in a document of their own.
    static let library: Set<String> = ["hq.prompts.library", "hq.voice.wordFixes"]

    /// Settings kept per gateway account (or per account and bot), by the start of their key. The account's id on this
    /// device is in the key; on the gateway it reads `{account}`, so it lands on the account the other device has for
    /// the same gateway even when the two were signed in with different addresses.
    static let accountPrefixes: [String] = [
        "hq.favorite-commands|", "hermes.desktop.favorite-models|", "hermes.desktop.model-presets|", "dispatch.chat.recentModels|",
        "pages.kanbanTab.override.", "hqn.defaultProjectFolder.", "pages.filesRoot.", "hqn.botMessageColour.",
    ]

    static let accountToken = "{account}"

    private static let credentialWords = #"token|secret|passw|api[_-]?key|bearer|cookie|credential|session[_-]?key|private[_-]?key"#

    /// The key as the gateway knows it, or nil when it doesn't travel (in this document).
    static func synced(_ key: String, accountId: String, library: Bool) -> String? {
        if key.range(of: credentialWords, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if library { return self.library.contains(key) ? key : nil }
        if settings.contains(key) { return key }
        guard !accountId.isEmpty, accountPrefixes.contains(where: { key.hasPrefix($0) }), key.contains(accountId) else { return nil }
        let synced = key.replacingOccurrences(of: accountId, with: accountToken)
        return synced.range(of: credentialWords, options: [.regularExpression, .caseInsensitive]) == nil ? synced : nil
    }

    /// The key on this device for one from the gateway.
    static func local(_ synced: String, accountId: String) -> String? {
        guard synced.contains(accountToken) else { return synced }
        return accountId.isEmpty ? nil : synced.replacingOccurrences(of: accountToken, with: accountId)
    }
}

/// UserDefaults values as JSON, the type kept (a Bool stays a Bool, Data stays Data).
nonisolated enum SyncedDefaultsValue {
    static func encode(_ value: Any) -> JSONValue? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return ["b": .bool(number.boolValue)] }
            return ["n": .number(number.doubleValue)]
        case let string as String: return ["s": .string(string)]
        case let data as Data: return ["d": .string(data.base64EncodedString())]
        case let date as Date: return ["t": .number(date.timeIntervalSince1970)]
        case let array as [Any]:
            let items = array.compactMap(encode)
            return items.count == array.count ? ["a": .array(items)] : nil
        case let dictionary as [String: Any]:
            var items: [String: JSONValue] = [:]
            for (key, item) in dictionary { guard let encoded = encode(item) else { return nil }; items[key] = encoded }
            return ["o": .object(items)]
        default: return nil
        }
    }

    static func decode(_ json: JSONValue) -> Any? {
        guard let object = json.object, let (tag, value) = object.first, object.count == 1 else { return nil }
        switch tag {
        case "b": return value.bool
        case "n": return value.double.map { $0.rounded() == $0 && abs($0) < 1e15 ? NSNumber(value: Int($0)) : NSNumber(value: $0) }
        case "s": return value.string
        case "d": return value.string.flatMap { Data(base64Encoded: $0) }
        case "t": return value.double.map { Date(timeIntervalSince1970: $0) }
        case "a":
            guard let items = value.array else { return nil }
            let decoded = items.compactMap(decode)
            return decoded.count == items.count ? decoded : nil
        case "o":
            guard let items = value.object else { return nil }
            var decoded: [String: Any] = [:]
            for (key, item) in items { guard let one = decode(item) else { return nil }; decoded[key] = one }
            return decoded
        default: return nil
        }
    }
}

/// One of the two settings documents.
@MainActor final class SettingsSync: GatewaySynced {
    let syncName: String
    private let library: Bool
    private let accountId: String
    private let defaults: UserDefaults
    /// The time each synced key was last set, on this device or taken from another (ms).
    private var stamps: [String: Double]
    /// Each synced key's value as last seen here (nil: not set).
    private var values: [String: JSONValue]
    private var observer: NSObjectProtocol?
    private var writing = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    /// Told when a setting changed here.
    var syncChanged: (() -> Void)?
    /// Told after settings from another device were written (local keys), so screens that keep a copy read again.
    var onAdopted: (([String]) -> Void)?

    init(library: Bool, accountId: String, defaults: UserDefaults = .standard) {
        syncName = library ? "library" : "settings"
        self.library = library
        self.accountId = accountId
        self.defaults = defaults
        stamps = (defaults.dictionary(forKey: "hq.gatewaySync.stamps.\(library ? "library" : "settings")|\(accountId)") as? [String: Double]) ?? [:]
        values = [:]
        values = current()
        // A setting made before settings synced has no time: it gets the oldest one there is, so whichever device
        // reaches the gateway first sets the starting point and the other takes it (`unstamped`, ties to the gateway).
        for key in values.keys where stamps[key] == nil { stamps[key] = Self.unstamped }
        // [hang-watch] Taken on the writer's thread and passed to main without waiting: with `queue: .main` every
        // `defaults.set` off the main thread waited for main, so a writer holding a lock main was waiting on froze the
        // app for good (HangWatch counting a stall in StabilityCounts while main raised the longest one).
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleCheck() } }
        }
    }

    /// The time of a setting made before settings synced.
    static let unstamped: Double = 1
    private var check: Task<Void, Never>?

    /// UserDefaults says something changed (any key, often): looked at once things settle.
    private func scheduleCheck() {
        guard !writing, check == nil else { return }
        check = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.check = nil
            self.defaultsChanged()
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        check?.cancel()
        check = nil
    }

    private var stampsKey: String { "hq.gatewaySync.stamps.\(syncName)|\(accountId)" }

    /// The synced keys' values now, by their gateway key.
    private func current() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let synced = SyncedSettingKeys.synced(key, accountId: accountId, library: library),
                  let encoded = SyncedDefaultsValue.encode(value) else { continue }
            out[synced] = encoded
        }
        return out
    }

    /// Something in UserDefaults changed: the synced keys that differ get the time now.
    func defaultsChanged() {
        guard !writing else { return }
        let next = current()
        guard next != values else { return }
        let at = now()
        for key in Set(next.keys).union(values.keys) where next[key] != values[key] { stamps[key] = at }
        values = next
        defaults.set(stamps, forKey: stampsKey)
        syncChanged?()
    }

    func syncValue() -> JSONValue {
        var out: [String: JSONValue] = [:]
        for key in Set(values.keys).union(stamps.keys) {
            out[key] = ["at": .number(stamps[key] ?? 0), "v": values[key] ?? .null]
        }
        return .object(out)
    }

    /// Each setting: the newer of the two copies (any merge; a key never set here takes the gateway's).
    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        var written: [String] = []
        writing = true
        for (key, entry) in value.object ?? [:] {
            let at = entry["at"]?.double ?? 0
            let mine = stamps[key] ?? 0
            guard at > mine || (mine <= Self.unstamped && at >= mine),
                  let localKey = SyncedSettingKeys.local(key, accountId: accountId),
                  SyncedSettingKeys.synced(localKey, accountId: accountId, library: library) == key else { continue }
            let incoming = entry["v"] ?? .null
            stamps[key] = at
            guard incoming != (values[key] ?? .null) else { continue }
            if incoming.isNull {
                defaults.removeObject(forKey: localKey)
            } else if let decoded = SyncedDefaultsValue.decode(incoming) {
                defaults.set(decoded, forKey: localKey)
            } else { continue }
            written.append(localKey)
        }
        writing = false
        values = current()
        defaults.set(stamps, forKey: stampsKey)
        if !written.isEmpty {
            AppLog.note("sync", "\(syncName): \(written.count) taken from another device: \(written.sorted().prefix(12).joined(separator: ", "))")
            onAdopted?(written)
        }
    }
}
