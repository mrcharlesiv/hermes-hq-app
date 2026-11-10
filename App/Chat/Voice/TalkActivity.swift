// [talk-background] The voice conversation's Live Activity (docs/spec/3x-talk-background.md §3): started with the
// conversation, updated when the dock's words change, ended with it. TalkController calls in; the widget extension
// draws it. The Lock Screen's End and Mute buttons come back through `TalkActivityActions`.

import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor final class TalkActivity {
    static let shared = TalkActivity()

    /// Off while the app hosts unit tests: a conversation started by a test shows nothing on the simulator's Lock Screen.
    var enabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    /// The conversation's controller: the Lock Screen's buttons go to it.
    private weak var owner: TalkController?

    /// A running card goes stale this long after the app last sent it: an app that was killed (swiped away, or by iOS)
    /// can't end it, and it went on saying "Listening" with its clock running. A live conversation sends it again well
    /// before (`renewAfter`); the widget draws a stale card as over.
    nonisolated static let staleAfter: TimeInterval = 10 * 60
    static let renewAfter: TimeInterval = 4 * 60
    /// A conversation that paused or stopped while the app was away leaves its card up this long saying so (it went at
    /// once, with no sound and no word); coming back to the app takes it away, as the chat then says why.
    static let endedLinger: TimeInterval = 15 * 60

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// The shown activity's id (the `Activity` itself is not Sendable: each step looks it up off the main actor).
    private var activity: String?
    private var shown: TalkActivityAttributes.ContentState?
    private var sentAt = Date.distantPast
    /// An ended card left up on the Lock Screen (`ended(away:)`).
    private var lingering: String?
    /// Requests, updates and ends run one after another, in the order Talk made them.
    private var queue: Task<Void, Never>?
    #endif

    /// Launch: the buttons reach Talk, and an activity a killed app left on the Lock Screen goes.
    func launched() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        TalkActivityActions.handler = { action in
            guard let owner = TalkActivity.shared.owner else { return }
            switch action {
            case .end: owner.end()
            case .toggleMute: owner.toggleMute()
            }
        }
        guard enabled else { return }
        enqueue { await Self.end(id: nil, final: nil, dismissal: .immediate) }
        #endif
    }

    /// The app is in front again: a paused or stopped conversation's card goes (the chat shows why).
    func appBecameActive() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let id = lingering else { return }
        lingering = nil
        guard enabled else { return }
        enqueue { await Self.end(id: id, final: nil, dismissal: .immediate) }
        #endif
    }

    /// A conversation began in `chat` (the app is on screen, as ActivityKit requires).
    func began(_ name: String, chat: any ChatVoiceTurns, owner: TalkController) {
        self.owner = owner
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let link = Self.link(chat.storedSessionId)
        let attributes = TalkActivityAttributes(name: name, startedAt: Date(), link: link, accent: HQPalette.cardAccent)
        let state = TalkActivityAttributes.ContentState(phase: TalkDockView.Phase.starting.rawValue, title: "Starting…", muted: false,
                                                        link: link)
        let previous = activity, left = lingering
        activity = nil
        lingering = nil
        shown = state
        sentAt = Date()
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        enqueue { [weak self] in
            for old in [previous, left].compactMap(\.self) { await Self.end(id: old, final: nil, dismissal: .immediate) }
            let made = await Self.request(attributes, state)
            VoiceEvents.note(made.map { _ in "live activity shown" } ?? "live activity not shown")
            guard let self, let made, self.shown != nil else { return await Self.end(id: made, final: nil, dismissal: .immediate) }
            self.activity = made
        }
        #endif
    }

    /// The dock's words changed (Talk's `publish`, at least once a second while a conversation runs). The running time
    /// is kept by the system, so a tick changes nothing; an unchanged card is sent again only to keep it from going
    /// stale. `storedSessionId`: the chat's, once it has one (the card's tap opens it).
    func update(view: TalkDockView?, muted: Bool, storedSessionId: String? = nil) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let shown, let view else { return }
        let state = TalkActivityAttributes.ContentState(phase: view.phase.rawValue, title: TalkDockState.shortTitle(view), muted: muted,
                                                        link: Self.link(storedSessionId) ?? shown.link)
        let now = Date()
        guard state != shown || now.timeIntervalSince(sentAt) >= Self.renewAfter else { return }
        self.shown = state
        sentAt = now
        guard enabled else { return }
        enqueue { [weak self] in
            guard let id = self?.activity else { return }
            await Self.update(id: id, state)
        }
        #endif
    }

    /// The conversation ended. Ended by the person (or on screen) the card goes at once: the chat says how it ended.
    /// `away`: the conversation paused or stopped by itself while the app was away (two minutes of silence, a headset
    /// gone, a failure): the card stays a while with these words ("Voice Paused"), its clock stopped, so the Lock
    /// Screen doesn't just go blank.
    func ended(away: String? = nil) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let shown else { return }
        self.shown = nil
        #if DEBUG
        lastEnded = away
        #endif
        guard enabled else { return }
        let now = Date()
        let final = TalkActivityAttributes.ContentState(phase: "ended", title: away ?? "Ended", muted: false, link: shown.link, endedAt: now)
        enqueue { [weak self] in
            guard let self, let id = self.activity else { return }
            self.activity = nil
            guard away != nil else { return await Self.end(id: id, final: final, dismissal: .immediate) }
            self.lingering = id
            await Self.end(id: id, final: final, dismissal: .after(now.addingTimeInterval(Self.endedLinger)))
        }
        #endif
    }

    private static func link(_ storedSessionId: String?) -> String? {
        storedSessionId.map { "\(AppIdentity.current.urlScheme)://session/\($0)" }
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    @concurrent private static func request(_ attributes: TalkActivityAttributes,
                                            _ state: TalkActivityAttributes.ContentState) async -> String? {
        try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: Date().addingTimeInterval(staleAfter)),
                              pushType: nil).id
    }

    @concurrent private static func update(id: String, _ state: TalkActivityAttributes.ContentState) async {
        await Activity<TalkActivityAttributes>.activities.first { $0.id == id }?
            .update(.init(state: state, staleDate: Date().addingTimeInterval(staleAfter)))
    }

    /// Ends one activity (`id` nil: every one of ours, as a killed run left them).
    @concurrent private static func end(id: String?, final: TalkActivityAttributes.ContentState?, dismissal: ActivityUIDismissalPolicy) async {
        for activity in Activity<TalkActivityAttributes>.activities where id == nil || activity.id == id {
            await activity.end(final.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }
    #endif

    #if DEBUG
    /// Tests: the words the last conversation's card was left with (`ended(away:)`), nil when it went at once.
    private(set) var lastEnded: String?

    /// Tests: what the Lock Screen would show now (nil: nothing).
    var debugShown: (phase: String, title: String, muted: Bool)? {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        shown.map { ($0.phase, $0.title, $0.muted) }
        #else
        nil
        #endif
    }
    #endif
}
