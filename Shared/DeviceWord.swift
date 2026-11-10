// [m9/ipad] The device's name in user-facing wording: "iPhone" on a phone (the web app's wording), "iPad" on an iPad,
// [mac] "Mac" on the Mac. Set once at launch (App/AppDelegate.swift) before any screen reads it; never changes afterwards.

import Foundation
import Synchronization

nonisolated enum DeviceWord {
    nonisolated(unsafe) static var name = "iPhone"
    #if targetEnvironment(macCatalyst)
    /// [mac] The system that asks for permissions, keeps the Keychain and reports crashes, and where its settings live.
    static let system = "macOS"
    static let settingsApp = "System Settings"
    /// [mac] What you do to a control in instructions: "Tap Try Again" / "Click Try Again", "tap" / "click" mid-sentence;
    /// what opens a row's menu ("touch and hold" / "Control-click"); how you move a row ("touch and hold" / "drag").
    /// Accessibility hints keep "tap": VoiceOver has its own gestures.
    static let tap = "click", Tap = "Click"
    /// [mac] Stress test 2026-10-28 #11: a non-breaking hyphen, so a line never ends "Control-" (Tool Calls' footer).
    static let hold = "Control\u{2011}click"
    static let reorder = "drag"
    /// [mac] The device on its own in a sentence: "while iPhone is locked" (Apple's style for iPhone and iPad), "while
    /// your Mac is locked".
    static let subject = "your Mac", Subject = "Your Mac"
    /// [mac] For a sentence that names a touch gesture (swipe, pinch, pull down) and reads differently with a mouse.
    static let isMac = true
    /// [mac] How a page refreshes: "pull to refresh" / "press Command-R to refresh".
    static let refresh = "press Command-R to refresh"
    #else
    static let system = "iOS"
    static let settingsApp = "iOS Settings"
    static let tap = "tap", Tap = "Tap"
    static let hold = "touch and hold"
    static let reorder = "touch and hold"
    static var subject: String { name }
    static var Subject: String { name }
    static let isMac = false
    static let refresh = "pull to refresh"
    #endif

    /// Stress test 2026-10-28 #97, round 2 (both): a setting kept on this device names it — "Set on this Mac only." /
    /// "Set on this iPhone only." (was "this device" everywhere).
    static var onlyHere: String { "Set on this \(name) only." }
}

/// The computer the bots run on, in user-facing wording: one phrase everywhere (the sign-in errors' own), never
/// "gateway" (in Hermes that is the Telegram bridge), never bare "Hermes" in a chat (the main bot is named Hermes)
/// and never "this machine" (on a phone that reads as the phone).
nonisolated enum HostWord {
    static let phrase = "the computer running Hermes"
    static let sentence = "The computer running Hermes"

    /// [update-flow] The gateway in use by its name ("Studio"), so "too old" messages say "Update Hermes on Studio";
    /// set by AppModel when the gateway changes (nil: none, and the messages keep `phrase`).
    private static let current = Mutex<String?>(nil)
    static var gatewayName: String? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
    /// What "Update Hermes on …" names: the gateway in use, else the computer running Hermes.
    static var updateTarget: String { gatewayName ?? phrase }
}
