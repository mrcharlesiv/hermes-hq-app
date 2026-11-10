// [live-steps] The steps a reply's Lock Screen card names (LiveKit's LiveActivityContent). The app's own updates carry
// them plainly; a push from the gateway's add-on (hermes-hq-push 0.9.22+, once iOS has suspended the app) carries them
// sealed with this phone's push key — the same box as a sealed alert (PushSeal.swift), opening to
// `{"step": "running npm test", "recent": ["reading package.json"], "steps": 7}` — so the relay and Apple carry no
// words. Compiled into the app (its tests), the notification extension (with the rest of Shared/) and the widget
// extension (this file and PushSeal.swift only), which opens it with the keys it reads through its keychain group.

import Foundation

nonisolated enum LiveStepsSeal {
    /// The trail to draw: a pushed seal's, opened with `keys`, else the content's own. A seal no key here opens (a key
    /// this phone no longer holds, a tampered box) falls back to the content's own words, which are empty in a push.
    static func trail(_ state: LiveActivityContent, keys: () -> [Data]) -> LiveStepTrail {
        guard let seal = state.seal else { return state.trail }
        let outer: [AnyHashable: Any] = ["seal": ["v": seal.v, "kid": seal.kid, "box": seal.box] as [String: Any]]
        guard let inner = PushSeal.open(outer, keys: keys()) else { return state.trail }
        return trail(inner)
    }

    /// An opened seal's trail.
    static func trail(_ inner: [String: Any]) -> LiveStepTrail {
        LiveStepTrail(step: inner["step"] as? String, recent: inner["recent"] as? [String] ?? [],
                      steps: (inner["steps"] as? NSNumber)?.intValue ?? 0).cleaned()
    }
}
