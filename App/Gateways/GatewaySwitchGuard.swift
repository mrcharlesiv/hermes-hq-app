// Before the app moves to another gateway (the title menu, the Gateway page's rows, Add Gateway…): a live Talk
// conversation or a voice memo being recorded belongs to the gateway in use and ends with it (`AppModel.tearDown`), so
// the switch asks first. Nothing live: the switch goes ahead at once. A Screen in control hands back by itself; a memo
// in review waits as its chat's draft on that gateway (UX study #267). Connect links and QR codes ask too
// (`AppModel.handleLink`).

import UIKit

@MainActor enum GatewaySwitchGuard {
    /// What a switch would end now, in words (nil: nothing).
    static var liveWork: (message: String, action: String)? {
        if TalkController.shared.isLive {
            return ("Your Talk conversation ends when Hermes HQ switches gateways.", "End Talk and Switch")
        }
        // A take in review is kept as its chat's draft (MemoController.reset), so only one still recording asks.
        if MemoController.shared.takeId != nil {
            return ("The voice memo you’re recording is discarded when Hermes HQ switches gateways.", "Discard and Switch")
        }
        return nil
    }

    /// `name`: the gateway switched to (nil for Add Gateway…, whose sign-in picks it).
    static func confirm(switchingTo name: String?, from presenter: UIViewController?, then go: @escaping () -> Void) {
        guard let work = liveWork, let host = FailureAlert.topmost(presenter) else { go(); return }
        let alert = UIAlertController(title: name.map { "Switch to \($0)?" } ?? "Add a Gateway?", message: work.message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: name == nil ? "Continue" : work.action, style: .destructive) { _ in go() })
        alert.view.accessibilityIdentifier = "gateway.switch-guard"
        host.present(alert, animated: true)
    }
}
