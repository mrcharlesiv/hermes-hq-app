// [settings] The Share extension's haptics (docs/spec/3x-settings.md §1). The extension is its own process: it reads
// the app's Haptics switch from the App Group's defaults (the app writes it there, key `hqn.haptics`; absent = on).

import UIKit

enum ShareHaptics {
    static var isOn: Bool {
        guard let group = ShareIdentity.appGroup, let defaults = UserDefaults(suiteName: group) else { return true }
        return defaults.object(forKey: "hqn.haptics") as? Bool ?? true
    }

    static func finished(_ ok: Bool) {
        guard isOn else { return }
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
    }

    /// A pick in the sheet's own list (a bot), as the app's custom pickers tick.
    static func selection() {
        guard isOn else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
