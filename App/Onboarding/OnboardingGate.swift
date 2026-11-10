// [onboarding] Which screen a signed-out launch starts on (docs/spec/3x-onboarding.md §3.2): the welcome for a first
// run, the form for a returning one (`returning`, `W:src/main.ts:206`).

import Foundation

enum OnboardingEntry: Equatable, Sendable { case welcome, form }

nonisolated enum OnboardingGate {
    /// DECISION D1: stands in for the web's "gateway last signed out of". Set once the app has shown; Sign Out keeps it.
    static let signedInBeforeKey = "hq.onboarding.signedInBefore"

    static func entry(linkAddress: String?, prefillAddress: String?, notice: String?, signedInBefore: Bool,
                      startAtForm: Bool) -> OnboardingEntry {
        func has(_ text: String?) -> Bool { !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let entry: OnboardingEntry = has(linkAddress) || has(prefillAddress) || has(notice) || signedInBefore || startAtForm ? .form : .welcome
        AppLog.trace("onboard", "onboarding entry: \(entry), signedInBefore=\(signedInBefore), hasLink=\(has(linkAddress)), hasPrefill=\(has(prefillAddress)), hasNotice=\(has(notice))")
        return entry
    }

    static var signedInBefore: Bool {
        get { UserDefaults.standard.bool(forKey: signedInBeforeKey) }
        set { if newValue { UserDefaults.standard.set(true, forKey: signedInBeforeKey) } else { UserDefaults.standard.removeObject(forKey: signedInBeforeKey) } }
    }

    /// DECISION D2: Release builds never start a first run on the form. DEBUG builds do unless `-HQDebugWelcome YES`,
    /// so every UI suite that launches a clean simulator and waits for the address field keeps working.
    static var startAtForm: Bool {
        #if DEBUG
        return !UserDefaults.standard.bool(forKey: "HQDebugWelcome")
        #else
        return false
        #endif
    }
}
