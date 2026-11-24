// [first-run] The one switch for the redrawn first run ("Hermes arrives", build/first-run/BRIEF.md) and the small
// decisions around it, kept pure so Tests/Onboarding/FirstRunArrivalTests.swift reads them. On by default since public
// beta 1247 (owner 2026-11-23, "Let's make this live in prod"); always off on the Mac and in the Add Gateway sheet.
//
//   -HQFirstRunArrival NO         today's first run instead (a stored default, so a launch argument sets it)
//   -HQFirstRunArrival YES        the arrival, even under the debug hooks below
//
// In DEBUG builds a launch with any -HQ…/-hqn. argument (every UI test's launch) keeps today's first run unless the
// switch is named: the UI families were written against it, and the arrival has its own walk (e2e-first-run.sh).

import Foundation

nonisolated enum FirstRunArrival {
    static let key = "HQFirstRunArrival"

    /// The seam: is the redrawn first run on for this device?
    static var isOn: Bool {
        let defaults = UserDefaults.standard
        let stored: Bool? = defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
        #if DEBUG
        let hooks = ProcessInfo.processInfo.arguments.contains { ($0.hasPrefix("-HQ") || $0.hasPrefix("-hqn.")) && $0 != "-\(key)" }
        #else
        let hooks = false
        #endif
        return allowed(stored: stored, debugHooks: hooks, isMac: DeviceWord.isMac)
    }

    /// The switch's rules: on unless turned off, off under the debug hooks unless named, and never on the Mac.
    static func allowed(stored: Bool?, debugHooks: Bool = false, isMac: Bool) -> Bool {
        guard !isMac else { return false }
        if let stored { return stored }
        return !debugHooks
    }

    /// Whether a flow in this mode draws the first run: the signed-out root only (never the Add Gateway sheet).
    static func applies(on: Bool, root: Bool) -> Bool { on && root }

    /// What follows a sign-in in the first run.
    enum Next: Equatable {
        /// Hermes is here (the arrival), then the app.
        case arrival
        /// Straight into the app, as main does.
        case app
        /// The Update screen, as main does: the arrival is skipped.
        case update
    }

    /// `.update` always wins; the arrival only where the first run is drawn.
    static func next(after outcome: SignInOutcome, drawn: Bool) -> Next {
        switch outcome {
        case .update: .update
        case .enter: drawn ? .arrival : .app
        }
    }

    /// The bot whose face arrives: the profile named "default", else the one marked default, else the first.
    static func arriving(_ profiles: [RosterProfile]) -> RosterProfile? {
        profiles.first { $0.name == "default" } ?? profiles.first(where: \.isDefault) ?? profiles.first
    }

    /// The others who came with it (never counted unless the list is in).
    static func others(_ profiles: [RosterProfile]) -> [RosterProfile] {
        guard let main = arriving(profiles) else { return [] }
        return profiles.filter { $0.name != main.name }
    }
}
