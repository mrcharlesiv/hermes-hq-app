// [share] Which process rotated the Nous pair (2026-10-23: the owner was signed out on an update and the logs could not
// say who had spent the pair). The Share extension has no diagnostic log of its own, so each of its rotations leaves a
// content-free line (when, and how it went) in the App Group; the app writes them to its log at its next refresh.

import Foundation

nonisolated enum ShareAuthTrail {
    static let key = "hq.share.nousRotations"
    static let keep = 20

    /// The extension's side: one line, e.g. "rotated the pair at 2026-10-24 03:04:44 UTC".
    static func record(_ outcome: String, at date: Date = Date(), defaults: UserDefaults? = shared) {
        guard let defaults else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append("\(outcome) at \(f.string(from: date))")
        defaults.set(Array(lines.suffix(keep)), forKey: key)
    }

    /// The app's side: the lines since the last drain (oldest first), cleared.
    static func drain(defaults: UserDefaults? = shared) -> [String] {
        guard let defaults, let lines = defaults.stringArray(forKey: key), !lines.isEmpty else { return [] }
        defaults.removeObject(forKey: key)
        return lines
    }

    static var shared: UserDefaults? { ShareIdentity.appGroup.flatMap { UserDefaults(suiteName: $0) } }
}
