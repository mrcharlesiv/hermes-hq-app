// [settings] Largest Attachment (docs/spec/3x-settings.md §4; the web phone's `hermes.attachmentLimitMb`,
// `ios/App/App/HermesPlatform.swift` clamps 1…32, default 32): the largest file this iPhone attaches or loads inline,
// in MB. On this iPhone only. Every reader of the old fixed 32 MB asks here.
// Tester report 2026-11-07 ("Can't upload files like videos larger than 32MB"): the web phone's 32 was its own
// (base64 in memory); Hermes takes up to 100 MB on `/api/files/upload-stream` (`hermes_cli/web_server.py`
// `_MANAGED_FILE_MAX_BYTES`), which this app streams from disk. So 1…100, 100 by default; a lower setting is kept.

import Foundation

nonisolated enum AttachmentLimit {
    static let range = 1...100
    static let defaultMB = 100
    static let key = "hqn.attachmentLimitMb"
    static let didChange = Notification.Name("hqn.attachmentLimit.changed")

    /// 1…100; anything unreadable (absent, text, a fraction that is not a number) is the default.
    static var megabytes: Int {
        get { megabytes(in: .standard) }
        set { if set(newValue, in: .standard) { NotificationCenter.default.post(name: didChange, object: nil) } }
    }

    static func megabytes(in defaults: UserDefaults) -> Int { clamp(defaults.object(forKey: key)) }

    /// Stores `value` clamped (the default is stored as nothing); answers whether the limit changed.
    @discardableResult
    static func set(_ value: Int, in defaults: UserDefaults) -> Bool {
        let value = min(max(value, range.lowerBound), range.upperBound)
        let before = megabytes(in: defaults)
        if value == defaultMB { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        return value != before
    }

    static var bytes: Int64 { Int64(megabytes) * 1024 * 1024 }
    static var isDefault: Bool { megabytes == defaultMB }

    static func clamp(_ stored: Any?) -> Int {
        guard let number = stored as? NSNumber, !(stored is String) else { return defaultMB }
        let value = number.doubleValue
        guard value.isFinite else { return defaultMB }
        return min(max(Int(value.rounded(.down)), range.lowerBound), range.upperBound)
    }

    /// Why an item was refused. At the default the limit is the app's own; below it, the person's setting, with the
    /// way to change it.
    static func refusal(name: String, megabytes: Int = AttachmentLimit.megabytes, app: String = AppIdentity.current.displayName) -> String {
        megabytes >= defaultMB
            ? "“\(name)” is larger than \(defaultMB) MB, the most \(app) can send."
            : "“\(name)” is larger than \(megabytes) MB, the largest attachment this \(DeviceWord.name) is set to send. You can change it in Settings › \(DeviceWord.isMac ? "Chat Behavior › " : "")Largest Attachment."   // [mac] Stress test 2026-10-28 #81, round 2
    }

    /// The Settings page's footer (the web phone's wording, `build/fe-platform-gates.ts`), with this build's name.
    static func footer(app: String = AppIdentity.current.displayName) -> String {
        // [mac] Stress test 2026-10-28 round 6: the Mac's row has its own "MB" beside the number, so its help says only
        // what the field doesn't (the web phone's "in MB" and "which is the default" said it twice).
        if DeviceWord.isMac { return macFooter(app: app) }
        return "The largest file \(app) attaches or previews, in MB. Up to \(defaultMB), which is the default. Set on this \(DeviceWord.name) only, for every bot."
    }

    /// [mac] The Mac row's help, beside a field that shows "MB".
    /// [mac] Stress test 2026-10-28 round 7: "…up to 32 (the default)…" read as a maximum with no unit; now plainly what
    /// the number does and the default with its unit. `app` is kept for callers; the sentence no longer needs it.
    static func macFooter(app: String = AppIdentity.current.displayName) -> String {
        "Files larger than this aren’t attached or previewed. Default: \(defaultMB) MB. Set on this Mac for every bot."
    }
}
