// [offline] The launch screen's machine (docs/spec/3x-offline.md §3.1, §3.2), a port of the web app's
// `src/launch-screen.ts`. The screen is up from the first frame: the icon alone; an activity indicator once the wait is
// noticeable; a caption that says what it waits for; after 12 s still not connected, the usual cause and the two
// buttons. It leaves once the app is connected with content (or content saved on this phone), and a first list gets
// 5 s to fill once the gateway is open before the app shows with its own loading state.

import Foundation

/// What still stands between the launch screen and an app worth showing: the gateway is not open and nothing saved is
/// on show (`cover`), or it is open and a first list is still loading (`loading`). nil = content.
nonisolated enum LaunchBlocker: Sendable, Equatable { case cover, loading }

@MainActor protocol LaunchContentSource: AnyObject {
    var launchBlocker: LaunchBlocker? { get }
}

@MainActor final class LaunchGate {
    nonisolated enum Phase: Sendable, Equatable { case shown, leaving, gone }

    nonisolated struct View: Sendable, Equatable {
        var phase: Phase = .shown
        /// The activity indicator, only once startup takes long enough to need one.
        var spinner = false
        /// The caption under the icon: why the wait is taking long, or why startup stopped.
        var status = ""
        /// Try Again / Change Address or Sign In, once the wait is long enough that the user may be stuck.
        var actions = false
    }

    nonisolated struct Timing: Sendable {
        /// A quick launch shows only the icon; the indicator appears once waiting is noticeable.
        var spinner: TimeInterval = 0.9
        /// A caption explains a wait this long.
        var status: TimeInterval = 4
        /// Still connecting after this long: point at the usual cause.
        var stalled: TimeInterval = 12
        /// Once the gateway is open, a first list gets this long to fill before the app shows with its own loading state.
        var content: TimeInterval = 5
        /// The app must stay ready this long, so one placeholder handing over to the next does not end the launch early.
        var settle: TimeInterval = 0.1
        /// The only startup fade-out; touches release at its start.
        var leave: TimeInterval = 0.12
        static let standard = Timing()
    }

    nonisolated enum Status {
        static let connecting = "Connecting to Hermes…"
        static let loading = "Loading…"
        static let stalled = "Still connecting. Check that the computer running Hermes is on and awake."
        /// Only for a gateway reached through Tailscale: a Nous or public address needs no Tailscale on this phone.
        static let stalledTailscale = "Still connecting. Check that the computer running Hermes is on and awake, and that Tailscale is on here."
        /// A Nous agent: no computer to wake; it may be stopped or still starting (audit 06-11).
        static let stalledNous = "Still connecting. Your Nous agent may be stopped or still starting."
        static func stalled(throughTailscale: Bool, nous: Bool = false) -> String {
            nous ? stalledNous : throughTailscale ? stalledTailscale : stalled
        }
    }

    private let timing: Timing
    private let clock: any FlightClock
    private let blocker: @MainActor () -> LaunchBlocker?
    /// Whether the gateway being waited on is reached through Tailscale (read when the 12 s caption is written).
    private let throughTailscale: @MainActor () -> Bool
    /// Whether that gateway is a Nous agent.
    private let nousHosted: @MainActor () -> Bool
    private let render: @MainActor (View) -> Void

    private(set) var view = View()
    private var failed = false
    private var mounted = false
    private var contentDeadline = false
    private var timers: [any FlightTimer] = []
    private var contentTimer: (any FlightTimer)?
    private var settleTimer: (any FlightTimer)?

    init(timing: Timing = .standard, clock: (any FlightClock)? = nil, blocker: @escaping @MainActor () -> LaunchBlocker?,
         throughTailscale: @escaping @MainActor () -> Bool = { false }, nousHosted: @escaping @MainActor () -> Bool = { false },
         render: @escaping @MainActor (View) -> Void) {
        self.timing = timing
        self.clock = clock ?? LiveFlightClock.shared
        self.blocker = blocker
        self.throughTailscale = throughTailscale
        self.nousHosted = nousHosted
        self.render = render
        show()
    }

    var phase: Phase { view.phase }
    var isMounted: Bool { mounted }

    private func publish() { render(view) }

    private func later(_ seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) {
        timers.append(clock.schedule(after: seconds, run))
    }

    private func clear() {
        for timer in timers { timer.cancel() }
        timers = []
        contentTimer?.cancel(); contentTimer = nil
        settleTimer?.cancel(); settleTimer = nil
    }

    private func arm() {
        later(timing.spinner) { [weak self] in
            guard let self, self.view.phase == .shown, !self.failed, !self.view.spinner else { return }
            self.view.spinner = true
            self.publish()
        }
        later(timing.status) { [weak self] in self?.waitingCaption() }
        later(timing.stalled) { [weak self] in
            guard let self, self.view.phase == .shown, !self.failed, !self.mounted || self.blocker() == .cover else { return }
            self.view.status = Status.stalled(throughTailscale: self.throughTailscale(), nous: self.nousHosted())
            self.view.actions = true
            self.publish()
        }
    }

    private func waitingCaption() {
        guard !failed, view.phase == .shown else { return }
        let now: LaunchBlocker? = mounted ? blocker() : .cover
        view.status = now == .loading ? Status.loading : Status.connecting
        publish()
    }

    private func show() {
        clear()
        view = View()
        failed = false; mounted = false; contentDeadline = false
        publish()
        arm()
    }

    private func leave() {
        guard view.phase == .shown else { return }
        clear()
        view.phase = .leaving; view.spinner = false; view.actions = false
        publish()
        later(timing.leave) { [weak self] in
            guard let self else { return }
            self.view.phase = .gone; self.view.status = ""
            self.publish()
        }
    }

    private func ready(_ now: LaunchBlocker?) -> Bool { now == nil || (now == .loading && contentDeadline) }

    /// The stores or the connection changed: is the app worth showing now?
    func check() {
        guard view.phase == .shown, !failed, mounted else { return }
        let now = blocker()
        // The content allowance starts once the gateway is open, however long connecting took, and once per launch.
        if now != .cover, contentTimer == nil, !contentDeadline {
            contentTimer = clock.schedule(after: timing.content) { [weak self] in
                guard let self else { return }
                self.contentTimer = nil
                self.contentDeadline = true
                self.check()
            }
        }
        guard ready(now) else {
            settleTimer?.cancel(); settleTimer = nil
            if view.status == Status.connecting, now == .loading { view.status = Status.loading; publish() }
            return
        }
        guard settleTimer == nil else { return }
        settleTimer = clock.schedule(after: timing.settle) { [weak self] in
            guard let self else { return }
            self.settleTimer = nil
            if self.ready(self.blocker()) { self.leave() }
        }
    }

    /// Restoring or signing in finished and the app is loading again: the launch screen covers it.
    func booting() { if view.phase != .shown { show() } }

    /// An account is active and the app can be shown: the launch screen leaves as soon as it is connected with content.
    func mount() {
        guard view.phase == .shown, !mounted else { return }
        mounted = true
        // An error reported before mounting was not fatal after all: the app is up.
        if failed { failed = false; view.status = ""; view.actions = false; publish() }
        check()
    }

    /// Sign-in (or the offline screen) owns the screen.
    func hide() { leave() }

    /// Startup stopped before the app was on screen: the icon stays with the reason and the buttons.
    func fail(_ message: String) {
        guard view.phase == .shown else { return }
        clear()
        failed = true
        view.spinner = false; view.status = message; view.actions = true
        publish()
    }

    /// Try Again: the timers start over. The indicator stays, the caption is back to connecting, the buttons leave.
    func retry() {
        guard view.phase == .shown else { return }
        clear()
        failed = false; contentDeadline = false
        view.spinner = true; view.status = Status.connecting; view.actions = false
        publish()
        arm()
        check()
    }

    var hasFailed: Bool { failed }
}
