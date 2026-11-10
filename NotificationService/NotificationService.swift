// The notification service extension (original identity only; com.charlesmcdowell.dispatch.notifications). Opens sealed
// alerts from the hermes-hq-push plugin before iOS shows them; the work is NotificationOpener's (Shared/, unit-tested in
// the app's tests). Never logs.
//
// [live] Best effort: a "reply finished" push (`turnDone`) also tries to end that turn's Live Activity here, before the
// app ever wakes up, so the Lock Screen can say Done instead of "Working…" until the app reopens (docs/spec/
// 3x-presence.md §17.4). Whether iOS actually lets this extension see activities the main app started is not
// documented and not verifiable in the Simulator (`xcrun simctl push` never runs this extension at all — see
// scripts/fixtures/push-gateway.py). The ActivityKit SDK itself has no `@available` restriction that marks `Activity`,
// `.activities`, `.update` or `.end` unavailable to an app extension (checked: ActivityKit.swiftinterface in the
// installed iOS SDK carries only macOS/macCatalyst/tvOS/watchOS platform exclusions, same as the main app). If iOS
// does not share the activity with this process, `Activity<HQLiveAttributes>.activities` is simply empty here and
// nothing happens — the 30-minute staleness rule (LiveActivityPlanner.staleAfter) is the fallback either way, exactly
// as if this file had never tried.

import UserNotifications
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

final class NotificationService: UNNotificationServiceExtension {
    private var deliver: Once?
    private var original: UNNotificationContent?

    /// The content handler, called once: by whoever finishes first — the Live Activity try below, or
    /// `serviceExtensionTimeWillExpire` if that runs long (which must still show the opened alert, never the sealed one).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((UNNotificationContent) -> Void)?
        init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }
        func send(_ content: UNNotificationContent) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(content)
        }
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let once = Once(contentHandler)
        deliver = once
        original = request.content
        // Neither `UNNotificationContent` nor a plain `(UNNotificationContent) -> Void` is `Sendable` in this SDK;
        // `nonisolated(unsafe)` is the sanctioned opt-out where the compiler can't see what's true in practice: iOS
        // calls this extension's two overrides one at a time, never from two threads at once, so a short-lived Task
        // using either value right after is no less safe than finishing synchronously would have been.
        nonisolated(unsafe) let opened = NotificationOpener.process(request.content, environment: .live)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if let dispatch = opened.userInfo["dispatch"] as? [String: Any], let subject = LiveActivityPush.turnFinished(dispatch) {
            // Held until this finishes (or `serviceExtensionTimeWillExpire` cuts it short, showing the opened alert
            // itself): the alert shows either way, just not before the Lock Screen had its chance to catch up. Only
            // the one-shot `once` crosses into the Task, never `self`.
            Task {
                await Self.endLiveActivity(subject)
                once.send(opened)
            }
            return
        }
        #endif
        finish(opened)
    }

    override func serviceExtensionTimeWillExpire() {
        guard let original else { return }
        finish(NotificationOpener.expired(original) { PushAlertDiagnostics.record($0) })
    }

    private func finish(_ content: UNNotificationContent) {
        deliver?.send(content)
        deliver = nil
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// `subject` is a bot's turn (profile id). If this process can see the activity the app started, end it Done,
    /// lingering as the app's own ending does while it is away (LiveActivityTiming.linger) — found by no means
    /// other than the subject matching: this extension never touches the app's own planner state.
    private nonisolated static func endLiveActivity(_ subject: LiveActivitySubject) async {
        // Counted (PushAlertDiagnostics; the app's log names them when it next ends a card): whether this extension
        // ever sees the app's cards at all. "none" (no card in sight) also counts the many short turns that had none;
        // only "other", "over" or "ended" show it can see them — never any of those, and only the add-on's push ends one.
        let cards = Activity<HQLiveAttributes>.activities
        guard let activity = cards.first(where: { $0.attributes.subject == subject }) else {
            PushAlertDiagnostics.record(cards.isEmpty ? "liveEnd.none" : "liveEnd.other")
            return
        }
        var content = activity.content.state
        guard !content.isOver else {
            PushAlertDiagnostics.record("liveEnd.over")
            return
        }
        PushAlertDiagnostics.record("liveEnd.ended")
        let now = Date()
        content.phase = .done
        content.endedAt = now
        let linger = LiveActivityTiming.linger(ran: now.timeIntervalSince(content.startedAt))
        await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(linger)))
    }
    #endif
}
