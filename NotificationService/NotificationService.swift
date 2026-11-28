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
        private var opened: UNNotificationContent?

        init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }

        func setOpened(_ content: UNNotificationContent) {
            lock.lock()
            opened = content
            lock.unlock()
        }

        func send(_ content: UNNotificationContent) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(content)
        }

        func expire(original: UNNotificationContent, record: (String) -> Void) {
            lock.lock()
            let handler = self.handler
            let ready = self.opened
            self.handler = nil
            lock.unlock()
            guard let handler else { return }
            handler(NotificationOpener.expired(original, opened: ready, record: record))
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
        once.setOpened(opened)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if let dispatch = opened.userInfo["dispatch"] as? [String: Any], let target = LiveActivityPush.turnFinishedTarget(dispatch) {
            // Held until this finishes (or `serviceExtensionTimeWillExpire` cuts it short, showing the opened alert
            // itself): the alert shows either way, just not before the Lock Screen had its chance to catch up. Only
            // the one-shot `once` crosses into the Task, never `self`.
            Task {
                await Self.endLiveActivity(profile: target.profile, session: target.session)
                once.send(opened)
            }
            return
        }
        #endif
        finish(opened)
    }

    override func serviceExtensionTimeWillExpire() {
        guard let original else { return }
        deliver?.expire(original: original) { PushAlertDiagnostics.record($0) }
        deliver = nil
    }

    private func finish(_ content: UNNotificationContent) {
        deliver?.send(content)
        deliver = nil
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// Marks a finished turn Done on whichever Live Activity is showing it — either the grouped card
    /// (`HQGroupedLiveAttributes`) or an individual card (`HQLiveAttributes`, matching main bot chat or side chat).
    private nonisolated static func endLiveActivity(profile: String, session: String?) async {
        let now = Date()
        var handled = false

        // 1. Grouped Live Activity: flip the matching row to Done; end the card only when no active rows remain.
        for group in Activity<HQGroupedLiveAttributes>.activities where group.activityState != .ended {
            guard let updated = group.content.state.markingTurnDone(profile: profile, session: session, now: now) else { continue }
            handled = true
            PushAlertDiagnostics.record("liveEnd.ended")
            if updated.isOver {
                let linger = updated.dismissalLinger(now: now)
                await group.end(ActivityContent(state: updated, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(linger)))
            } else {
                await group.update(ActivityContent(state: updated, staleDate: now.addingTimeInterval(LiveActivityTiming.staleAfter)))
            }
        }

        // 2. Individual Live Activity (ungrouped mode): match side chat (`profile/session`) first, then main bot chat (`profile`)
        // only when it has no session id or matches `session` (never clobbering an active main chat on an untracked side-chat push).
        let cards = Activity<HQLiveAttributes>.activities
        let nonEmptySession = session.flatMap { $0.isEmpty ? nil : $0 }
        let sideSubject = nonEmptySession.map { LiveActivitySubject(kind: .turn, id: "\(profile)/\($0)") }
        let mainSubject = LiveActivitySubject(kind: .turn, id: profile)
        let activity: Activity<HQLiveAttributes>? = if let nonEmptySession {
            sideSubject.flatMap { s in cards.first { $0.attributes.subject == s } }
                ?? cards.first { card in
                    guard card.attributes.subject == mainSubject else { return false }
                    let cardSession = card.attributes.sessionId
                    return cardSession == nil || cardSession == nonEmptySession
                }
        } else {
            cards.first { $0.attributes.subject == mainSubject }
        }
        if let activity {
            var content = activity.content.state
            guard !content.isOver else {
                if !handled { PushAlertDiagnostics.record("liveEnd.over") }
                return
            }
            PushAlertDiagnostics.record("liveEnd.ended")
            content.phase = .done
            content.endedAt = now
            let linger = LiveActivityTiming.linger(ran: now.timeIntervalSince(content.startedAt))
            await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(linger)))
            return
        }

        if !handled {
            let anyShown = !cards.isEmpty || !Activity<HQGroupedLiveAttributes>.activities.isEmpty
            PushAlertDiagnostics.record(anyShown ? "liveEnd.other" : "liveEnd.none")
        }
    }
    #endif
}
