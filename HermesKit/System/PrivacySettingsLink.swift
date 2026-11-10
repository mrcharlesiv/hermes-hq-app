// [mac] Mac polish #11: the way back to a permission the person once refused (microphone, camera, Photos, Contacts,
// Location, Calendar, Reminders, notifications). `UIApplication.openSettingsURLString` opens nothing on the Mac (the
// link reports success and no window comes), so every "Open Settings" there did nothing, and "in Settings" read as
// Hermes HQ's own Settings window. On the Mac the button opens the permission's own pane of System Settings › Privacy
// & Security (notifications: the system's notifications link, which the Mac opens), and the words say System Settings.
// The iPhone and iPad keep the app's page in Settings and their words, as before.

import Foundation
import UIKit

nonisolated enum PrivacySettingsLink {
    /// A permission's pane: System Settings' own anchors in Privacy & Security.
    enum Pane: String, CaseIterable, Sendable {
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case photos = "Privacy_Photos"
        case contacts = "Privacy_Contacts"
        case location = "Privacy_LocationServices"
        case calendars = "Privacy_Calendars"
        case reminders = "Privacy_Reminders"
        /// Privacy & Security itself, for a permission with no pane of its own.
        case privacy = ""
        /// Notifications › Hermes HQ.
        case notifications = "notifications"
    }

    /// Where a message sends the person: "in System Settings" on the Mac, "in Settings" on the iPhone and iPad.
    static var place: String { DeviceWord.isMac ? DeviceWord.settingsApp : "Settings" }
    /// The button that goes there: "Open System Settings" / "Open Settings".
    static var openTitle: String { "Open \(place)" }

    /// The Mac's link to a pane. System Settings still takes the old Security pane's name with an anchor (its Privacy
    /// extension says so: `legacyBundleIdentifier` com.apple.preference.security).
    static func macURL(_ pane: Pane) -> URL? {
        switch pane {
        case .notifications: URL(string: UIApplication.openNotificationSettingsURLString)
        case .privacy: URL(string: "x-apple.systempreferences:com.apple.preference.security")
        default: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        }
    }

    /// The link for this device: the Mac's pane, or the app's own page in Settings.
    static func url(_ pane: Pane) -> URL? {
        #if targetEnvironment(macCatalyst)
        macURL(pane)
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    @MainActor static func open(_ pane: Pane) {
        guard let url = url(pane) else { return }
        AppLog.trace("settings", "open system settings: \(pane)")
        UIApplication.shared.open(url)
    }
}
