// The one alert this feature shows (docs/spec/3x-intents.md DECISION I8, §7.4, §8.2, §8.4, §9.4): a title, the
// sentence, its buttons, over whatever is on top. One at a time: a newer one replaces it, and a shortcut that then
// works takes it away. A system alert, because a shortcut may fail before any chat is open (the chat's own memo notice
// card cannot carry it) and the owner must be able to read why.

import UIKit

@MainActor final class IntentsNotice {
    static let shared = IntentsNotice()
    static let accessibilityIdentifier = "intents.notice"

    private weak var alert: UIAlertController?
    private var content: IntentsNoticeContent?
    /// Bumped by every show and dismiss: a presentation that was waiting for a transition gives way to a newer one.
    private var generation = 0
    /// A button was tapped (the runtime; a recorder in tests).
    var onChoice: (IntentsNoticeContent.Choice, IntentsNoticeContent) -> Void = { choice, content in
        IntentsRuntime.shared.choose(choice, from: content)
    }

    func isShowing(_ notice: IntentsNoticeContent) -> Bool {
        guard content == notice else { return false }
        // Up, or about to be (waiting for a transition to finish).
        return alert?.presentingViewController != nil || (alert == nil && waiting)
    }

    private var waiting = false

    func show(_ notice: IntentsNoticeContent) {
        if isShowing(notice) { return }
        generation += 1
        content = notice
        waiting = true
        let generation = generation
        if let alert, alert.presentingViewController != nil {
            alert.dismiss(animated: false) { [weak self] in self?.present(notice, generation, attempt: 0) }
        } else {
            present(notice, generation, attempt: 0)
        }
    }

    func dismiss() {
        generation += 1
        content = nil
        waiting = false
        if let alert, alert.presentingViewController != nil { alert.dismiss(animated: true) }
        alert = nil
    }

    private func present(_ notice: IntentsNoticeContent, _ generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        // A screen that is mid-transition cannot present: wait for it (≤ 3 s), then say it anyway.
        guard let host = FailureAlert.topmost(MainTabController.current) ?? Self.anyRoot(), host.viewIfLoaded?.window != nil,
              attempt >= 30 || (!host.isBeingPresented && !host.isBeingDismissed && host.transitionCoordinator == nil) else {
            guard attempt < 30 else {
                AppLog.note("intents", "notice not shown: no settled screen to present it on")
                waiting = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.present(notice, generation, attempt: attempt + 1) }
            return
        }
        // Another alert is on top (the push set-up offer, "Change Model?"): UIKit will not present over an alert, and
        // the sentence would be lost. It goes first (whoever awaits its button is answered, `AlertAnswer`).
        if host is UIAlertController, attempt < 30 {
            host.dismiss(animated: false) { [weak self] in self?.present(notice, generation, attempt: attempt + 1) }
            return
        }
        let alert = UIAlertController(title: notice.title, message: notice.message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = Self.accessibilityIdentifier
        for button in notice.buttons {
            let style: UIAlertAction.Style = button.role == .destructive ? .destructive : button.role == .cancel ? .cancel : .default
            let action = UIAlertAction(title: button.title, style: style) { [weak self] _ in
                guard let self else { return }
                if self.content == notice { self.content = nil; self.alert = nil }
                self.onChoice(button.choice, notice)
            }
            alert.addAction(action)
            if button.role == .preferred { alert.preferredAction = action }
        }
        host.present(alert, animated: true)
        // Refused (another presentation won the race): the sentence is not dropped, it is tried again.
        guard alert.presentingViewController != nil else {
            guard attempt < 30 else {
                AppLog.note("intents", "notice not shown: lost the presentation race 30 times")
                waiting = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.present(notice, generation, attempt: attempt + 1) }
            return
        }
        switch notice.haptic {
        case .none: break
        case .warning: Haptics.play(.warning)
        case .error: Haptics.play(.error)
        }
        self.alert = alert
        waiting = false
    }

    /// Before the tabs exist (the sign-in form): the key window's root, so a failure is still said.
    private static func anyRoot() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let root = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController { return FailureAlert.topmost(root) }
        }
        return nil
    }
}
