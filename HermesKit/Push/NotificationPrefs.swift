// Settings › Notifications as stored (the web app's own UserDefaults key `hermes.notificationPrefs`, so an update keeps
// what the person chose): Enable Notifications, one switch per kind, Show Previews; plus Bot Activity Banners (the
// reply peek). And the small routing rules an alert follows (which chat it opens, whether it alerts at all).

import Foundation

nonisolated struct NotificationPrefs: Equatable, Sendable {
    /// The kinds, in Settings order (vendor native-notifications.ts NATIVE_NOTIFICATION_KINDS), all on by default.
    static let kinds = ["approval", "input", "turnDone", "turnError", "backgroundDone", "credits", "plugin"]
    /// The switches Settings shows: only kinds something raises. "plugin" (Kanban's terminal events) is stored but has no
    /// watcher yet, so it is not drawn (never a switch that does nothing; docs/spec/3x-settings.md §15d).
    static let shown = kinds.filter { $0 != "plugin" }
    static let key = "hermes.notificationPrefs"
    static let bannersKey = "hermes.botActivityBanners"

    var enabled = true
    var kinds: [String: Bool] = [:]
    var previews = true

    func allows(_ kind: String) -> Bool { enabled && kinds[kind] != false }

    static func label(_ kind: String) -> String {
        switch kind {
        case "approval": "Approval Needed"
        case "input": "Input Needed"
        case "turnDone": "Response Ready"
        case "turnError": "Turn Failed"
        case "backgroundDone": "Background Task Finished"
        case "credits": "Credit Alerts"
        case "plugin": "Plugin Notifications"
        default: kind
        }
    }

    static func detail(_ kind: String) -> String {
        switch kind {
        case "approval": "A command is waiting for you to approve or reject it."
        case "input": "Hermes asked a question or needs a password or secret."
        case "turnDone": "A bot finished a reply while you were somewhere else."
        case "turnError": "A reply couldn’t finish."
        case "backgroundDone": "A backgrounded terminal command completed."
        case "credits": "Credit access is paused or restored."
        case "plugin": "A gateway plugin sent a notification."
        default: ""
        }
    }

    /// The preference a gateway kind or event names.
    static func preference(_ kind: String) -> String {
        kind == "approval.request" ? "approval" : kind == "message.complete" ? "turnDone" : kind
    }

    static func load(_ defaults: UserDefaults = .standard) -> NotificationPrefs {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return NotificationPrefs(enabled: raw["enabled"] as? Bool != false, kinds: raw["kinds"] as? [String: Bool] ?? [:],
                                 previews: raw["previews"] as? Bool != false)
    }

    func save(_ defaults: UserDefaults = .standard) {
        var raw = defaults.dictionary(forKey: Self.key) ?? [:]
        raw["enabled"] = enabled
        raw["kinds"] = kinds
        raw["previews"] = previews
        defaults.set(raw, forKey: Self.key)
    }

    /// Bot Activity Banners (the reply peek while the app is open). On by default.
    static func banners(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: bannersKey) as? Bool ?? true }
    static func setBanners(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: bannersKey) }

    /// Why Send Test Notification can't send yet, or nil (notification-settings-state.ts testNotificationBlocker).
    static func testBlocker(denied: Bool, prefs: NotificationPrefs) -> String? {
        if denied { return "Allow notifications for \(AppIdentity.current.displayName) in \(DeviceWord.settingsApp) first (Open Settings, above)." }
        if !prefs.enabled { return "Turn on Enable Notifications to send a test." }
        if prefs.kinds["turnDone"] == false { return "Turn on Response Ready to send a test." }
        return nil
    }
}

nonisolated enum NotificationRules {
    /// A stored or runtime session id an alert may name (letters, digits, - and _; at most 160).
    static func valid(_ session: String) -> Bool {
        !session.isEmpty && session.count <= 160 && session.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Like Messages: away, every reply and approval alerts; in the app, everything but the chat on screen.
    static func shouldPost(session: String, active: Bool, viewing: String?, viewingStored: String?) -> Bool {
        !active || (session != viewing && session != viewingStored)
    }

    /// Messages-style ordering in Notification Center: what needs an answer first, then the chat the user left.
    static func relevance(kind: String, session: String, viewing: String?) -> Double {
        switch kind {
        case "approval.request", "approval", "input": return 1
        case "turnError": return 0.8
        case "message.complete", "turnDone": return session == viewing ? 0.9 : 0.6
        case "backgroundDone": return 0.4
        default: return 0.3
        }
    }

    /// The chat an alert opens: its stored id when it carries one, else its session (a push's `dispatch.session` is the
    /// stored id), and the bot profile when known.
    static func target(_ info: [AnyHashable: Any]) -> (session: String, profile: String?)? {
        let remote = info["dispatch"] as? [String: Any]
        let session = info["session"] as? String ?? remote?["session"] as? String
        let stored = (info["stored"] as? String).flatMap { valid($0) ? $0 : nil } ?? session.flatMap { valid($0) ? $0 : nil }
        guard let stored else { return nil }
        let profile = (info["profile"] as? String ?? remote?["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (stored, profile)
    }

    /// The gateway account a pushed alert came from (the plugin's opaque account tag), nil for a local alert or a
    /// plugin that doesn't say (UX study #262: an alert from a gateway switched away from opens nothing here).
    static func account(_ info: [AnyHashable: Any]) -> String? {
        ((info["dispatch"] as? [String: Any])?["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A pushed alert's kind in the app's own names (UX study #261): an approval, a question, a failed reply or a
    /// background task keeps its kind; a finished reply, or a plugin too old to say, reads as `message.complete`.
    static func pushedKind(_ remote: [String: Any]) -> String {
        switch remote["kind"] as? String ?? "" {
        case "approval", "approval.request": return "approval.request"
        case "", "turnDone", "message.complete": return "message.complete"
        case let kind: return kind
        }
    }

    /// A `hermes://` (or this build's scheme) link: a chat to open, a gateway address for the sign-in form, or nothing.
    enum Link: Equatable { case session(String), connect(String) }

    static func link(_ url: URL, scheme: String) -> Link? {
        guard let given = url.scheme?.lowercased(), given == scheme.lowercased() || given == "hermes" else { return nil }
        switch url.host?.lowercased() {
        case "connect":
            return connectAddress(url).map { .connect($0) }
        case "session":
            guard url.query == nil, url.fragment == nil else { return nil }
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return valid(id) ? .session(id) : nil
        default:
            return nil
        }
    }

    /// hermes://connect?url=https://… (the connect QR on the gateway computer): a plain https address — a host with a dot,
    /// an optional port, nothing else. Never signs in by itself.
    static func connectAddress(_ url: URL) -> String? {
        guard url.host?.lowercased() == "connect", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value, raw.count <= 300, let target = URLComponents(string: raw),
              target.scheme == "https", let host = target.host, host.contains("."), target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil, target.path.isEmpty || target.path == "/" else { return nil }
        return "https://" + host.lowercased() + (target.port.map { ":\($0)" } ?? "")
    }
}
