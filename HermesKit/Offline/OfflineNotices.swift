// [offline] The two notices that are not the reconnect banner (docs/spec/3x-offline.md §5.2, §5.3), worded as the web
// app's `src/native-runtime.ts:60-74` words them (`${DEVICE}` → iPhone), and the rule that keeps each to one alert at
// a time.

import Foundation

nonisolated enum OfflineNotices {
    // Audit 06-14: one spelling of "Sign In Again" everywhere (title case, as the offline screen's button), and the
    // gateway named: with several saved, "Your gateway" didn't say which one.
    static let signInAgainTitle = "Sign In Again"
    static func signInAgainMessage(gateway name: String?) -> String {
        let who = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Your gateway"
        return "\(who) ended this \(DeviceWord.name)’s session. Sign in again to reconnect; your drafts are kept."
    }
    static let signInAgainAction = "Sign In Again"
    static let notNow = "Not Now"

    static let tooLargeTitle = "Message too large"
    static let tooLargeMessage = "Your gateway sent a message larger than 64 MB, which Hermes HQ on \(DeviceWord.name) can’t receive. "
        + "It was skipped; open this chat on \(HostWord.phrase) to see it."
    static let ok = "OK"
}

/// One alert at a time for a notice that can be asked for again while it shows, or while nothing can show (the app is
/// in the background, the launch screen still covers, another alert is up): never stacked, never lost.
nonisolated struct NoticeSlot: Sendable, Equatable {
    private(set) var showing = false
    private(set) var pending = false
    /// How many alerts this slot has let through.
    private(set) var presented = 0

    /// The notice is wanted. True = present it now; false = it already shows, or it waits for `resume`.
    mutating func request(canShow: Bool) -> Bool {
        if showing { return false }
        guard canShow else { pending = true; return false }
        pending = false
        showing = true
        presented += 1
        return true
    }

    /// The alert was answered. `again`: it is still owed (Not Now on an ended session) and shows at the next `resume`.
    mutating func dismissed(again: Bool = false) {
        showing = false
        pending = again
    }

    /// Notices can show again (the app is active, the app is on screen). True = present the one that waited.
    mutating func resume(canShow: Bool) -> Bool {
        guard pending else { return false }
        return request(canShow: canShow)
    }

    mutating func reset() { showing = false; pending = false }
}
