// One open Bot Screen (docs/spec/3x-screen.md §4): the status, the attach (observe, reclaim, dial, stream), the
// lease calls, eviction, pause and resume, the Mac health poll and leaving. A port of the vendor pane's state
// (`screen-pane.tsx`, `screen-state.ts`) plus the phone's rules (`bot-screen-phone.tsx`); the view only draws it.

import CoreGraphics
import Foundation

@MainActor final class ScreenSession {
    enum Conn: Equatable {
        case idle, attaching, live
        case error(title: String, detail: String?)
    }

    enum Fallback: Equatable { case unsupported, unavailable, blocked }

    /// What the viewer shows (S0–S7 of the spec).
    enum Phase: Equatable {
        case connecting
        /// nil: the status never arrived; else the failed call's message.
        case noAnswer(String?)
        case fallback(Fallback)
        case missing
        case off
        case attaching
        case live
        case ended(title: String, detail: String?)
    }

    enum Busy: Equatable { case take, give, force, start }

    /// One-shot moments the view answers with a pill, a haptic or an announcement.
    enum Notice: Equatable { case controlStarted, controlEnded, controlTaken, live }

    nonisolated struct Timing: Sendable {
        var statusWait: Duration = .seconds(20)
        var pauseDelay: Duration = .seconds(1)
        var retryDelay: Duration = .seconds(1)
        var failureWindow: TimeInterval = 10
        var evictionWindow: TimeInterval = 10
        var maxEvictions = 3
        var healthEvery: Duration = .seconds(15)
        var stuckAfter: TimeInterval = 8
        /// How long a finished handshake may go without its first picture (the Mac helper sends none while it has none).
        var firstPictureWait: TimeInterval = 20
        var pingEvery: Duration = .seconds(20)
    }

    struct Environment {
        var client: any GatewayClient
        var dial: @Sendable (_ path: String, _ ticket: String) async throws -> any ScreenSocketing
        var holds: ScreenHolds
        var health: MacScreenHealthReader
        var accountId: String
        var timing = Timing()
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// DECISION D9: polls double their interval in Low Power Mode or under thermal pressure.
        var slow: @MainActor () -> Bool = { ScreenPower.slow }
        /// What the service last knew of a bot's screen (its events and earlier Screens): a running one is attached
        /// at once on the first open.
        var cachedStatus: @MainActor (String) -> ScreenStatus? = { _ in nil }
    }

    static let streamEnded = "Screen Stopped"
    static let controlTaken = "Another viewer took control. Watching only."
    static let noPictureMac = "The Mac hasn’t sent a picture yet"
    static let noPicture = "The screen hasn’t sent a picture yet"

    let profile: String
    let name: String
    private let env: Environment

    // What the view reads.
    private(set) var status: ScreenStatus?
    private(set) var lease: ScreenLease?
    private(set) var viewer: ScreenViewer?
    private(set) var unavailable = false
    /// nil: no failure. "": the status never arrived. Else the failed call's message.
    private(set) var statusFailure: String?
    private(set) var conn: Conn = .idle
    private(set) var mac: MacScreen?
    /// The plugin's last health answer as sent (for "Check setup"); nil before the first read or when it is missing.
    private(set) var health: JSONValue?
    private(set) var errorLine: String?
    private(set) var busy: Busy?
    private(set) var framebuffer: (width: Int, height: Int)?
    private(set) var onView = true
    private(set) var left = false

    var onChange: (() -> Void)?
    var onFrame: ((CGImage, Int, Int) -> Void)?
    var onNotice: ((Notice) -> Void)?
    /// The service's cache (the row menu's label reads it).
    var report: ((ScreenSession) -> Void)?

    private var stream: ScreenStream?
    private var statusGeneration = 0
    private var attachGeneration = 0
    private var statusTimer: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var typeTask: Task<Void, Never>?
    private var dialedAt: TimeInterval = 0
    private var rapidEvictions = 0
    private var lastFailureAt: TimeInterval?
    private var ticketRetried = false
    private var autoRetry = false
    private var wasHolding = false
    private var mask: UInt8 = 0
    private var pointer: (x: Int, y: Int)?
    private var typer = ScreenTyper()
    private var typeToken = 0
    /// The first open went straight to observe on the service's cached status (once per session).
    private var seeded = false
    /// The status shown is that cached one, not yet confirmed by the gateway.
    private var unverifiedSeed = false

    init(profile: String, name: String, environment: Environment) {
        self.profile = profile
        self.name = name
        env = environment
    }

    // MARK: Derived

    var holding: Bool { ScreenWire.holds(lease, viewer) }
    /// A hold saved by an earlier run that the lease still names (§5.8): "You were in control".
    var held: SavedHold? { ScreenHolds.heldBefore(saved: env.holds.saved(env.accountId, profile), lease: lease, viewer: viewer) }
    var otherHolds: Bool { lease?.holder == .human && !holding && held == nil }
    var isMac: Bool { status?.isMac == true }
    /// On a Mac, control needs the plugin's word that input is ready.
    var canTake: Bool { !isMac || mac?.inputReady == true }
    var canSendInput: Bool { conn == .live && holding && stream != nil }
    var tone: ScreenTone { ScreenWire.tone(unavailable: unavailable, status: statusWithLease, viewer: viewer) }
    var label: String { ScreenWire.screenLabel(status) }
    var pacing: ScreenPacing { stream?.pacing ?? ScreenPacing() }

    /// A screen there is something to attach to.
    private var canAttach: Bool {
        guard let status, !unavailable else { return false }
        return status.supported && status.installed && status.running
    }

    private var statusWithLease: ScreenStatus? {
        guard var status else { return nil }
        if let lease { status.lease = lease }
        return status
    }

    var phase: Phase {
        if unavailable { return .fallback(.unavailable) }
        guard let status else { return statusFailure.map { .noAnswer($0.isEmpty ? nil : $0) } ?? .connecting }
        if !status.supported { return .fallback(.unsupported) }
        if !status.installed { return .missing }
        if !status.running { return status.blocker == nil ? .off : .fallback(.blocked) }
        switch conn {
        case .live: return .live
        case .error(let title, let detail): return .ended(title: title, detail: detail)
        case .idle, .attaching: return .attaching
        }
    }

    /// The control row's caption.
    var caption: String {
        if holding { return "You are in control" }
        if held != nil { return "You were in control" }
        return lease?.holder == .human ? "Another viewer is in control" : "\(name.isEmpty ? "The bot" : name) is in control"
    }

    // MARK: Status

    /// Reads the bot's status (every open, Retry, Check Again, and the resume signals while there is none).
    func open() {
        guard !left else { return }
        // [perf] First open of a screen the service already saw running: observe at once (its answer carries the
        // status), one gateway round trip fewer. A stale cache falls back to this status read (runAttach's catch).
        if !seeded, status == nil, statusFailure == nil, !unavailable, let seed = env.cachedStatus(profile),
           seed.supported, seed.installed, seed.running {
            seeded = true
            statusGeneration += 1
            statusTimer?.cancel()
            unverifiedSeed = true
            AppLog.note("screen", "open on the known status")
            apply(seed)
            afterStatus()
            return
        }
        seeded = true
        statusGeneration += 1
        let token = statusGeneration
        statusFailure = nil
        changed()
        statusTimer?.cancel()
        let wait = env.timing.statusWait
        statusTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, token == self.statusGeneration, self.status == nil, !self.unavailable, self.statusFailure == nil else { return }
            AppLog.note("screen", "status never arrived")
            self.statusFailure = ""
            self.changed()
        }
        Task { [weak self] in await self?.readStatus(token) }
    }

    /// A quiet re-read (after a stream ends, while the fallback is on view): a failure changes nothing.
    func refresh() {
        guard !left else { return }
        statusGeneration += 1
        let token = statusGeneration
        Task { [weak self] in await self?.readStatus(token, quiet: true) }
    }

    private func readStatus(_ token: Int, quiet: Bool = false) async {
        do {
            let value = try await env.client.call("display.status", ScreenWire.profileParams(profile), timeout: ScreenWire.statusTimeout)
            guard token == statusGeneration, !left else { return }
            guard let parsed = ScreenStatus.parse(value) else {
                if !quiet, status == nil { statusFailure = "The gateway’s answer could not be read" }
                changed()
                return
            }
            unavailable = false
            statusFailure = nil
            statusTimer?.cancel()
            unverifiedSeed = false
            apply(parsed)
            afterStatus()
        } catch {
            guard token == statusGeneration, !left, !(error is CancellationError) else { return }
            if ScreenWire.isUnavailable(error) {
                AppLog.note("screen", "unavailable")
                statusTimer?.cancel()
                unavailable = true
                status = nil
                lease = nil
                viewer = nil
                statusFailure = nil
                detach()
                conn = .idle
            } else if !quiet, status == nil, !unavailable {
                statusTimer?.cancel()
                // The request's own 20 s limit and the 20 s wait are the same event: "never arrived", in those words.
                statusFailure = (error as? RPCError)?.isTimeout == true ? "" : ScreenWire.message(error)
            }
            changed()
        }
    }

    /// A status from an event or a call's own result: newer than any request still in flight.
    private func applyAuthoritative(_ next: ScreenStatus) {
        statusGeneration += 1
        unverifiedSeed = false
        unavailable = false
        statusFailure = nil
        statusTimer?.cancel()
        apply(next)
    }

    private func apply(_ next: ScreenStatus) {
        status = next
        if let fresh = next.lease, !fresh.isOlder(than: lease) { lease = fresh }
        framebuffer = framebuffer ?? ScreenWire.size(next.geometry)
    }

    private func applyLease(_ next: ScreenLease) {
        guard !next.isOlder(than: lease) else { return }
        lease = next
    }

    /// What a new status means for the stream and the health poll.
    private func afterStatus() {
        if canAttach {
            if conn == .idle, onView, retryTask == nil { attach(auto: true) }
        } else {
            detach()
            conn = .idle
        }
        syncHealth()
        changed()
    }

    // MARK: Events (forwarded by the service)

    /// A `display.status` or `display.lease` frame.
    /// `about` is the bot the service worked the event out to be about (Hermes' `profile_key` is a home path, so a
    /// Screen that has no status yet cannot tell by the key alone: the UI test of "a late status replaces the page"
    /// caught exactly that once the stand-in sent paths as Hermes does).
    func handle(_ event: GatewayEvent, about: String? = nil) {
        guard !left else { return }
        let key = event.payload["profile_key"]?.string
        let named = about ?? event.payload["profile"]?.string
        guard named == profile || (key != nil && (key == status?.profileKey || key == profile)) else { return }
        switch event.type {
        case "display.status":
            guard let parsed = ScreenStatus.parse(event.payload) else { return }
            applyAuthoritative(parsed)
            afterStatus()
            if isMac, onView { Task { [weak self] in await self?.readHealth() } }     // a helper change is often why it was sent
        case "display.lease":
            guard let next = ScreenLease.parse(event.payload["lease"]) else { return }
            applyLease(next)
            changed()
        default: break
        }
    }

    /// The gateway connection is ready again after anything else: viewer ids belonged to the old connection.
    func gatewayReconnected() {
        guard !left else { return }
        AppLog.note("screen", "gateway back")
        guard status != nil else {
            if !unavailable { open() }
            return
        }
        guard onView, canAttach else { return }
        attach(auto: true, signal: true)
    }

    /// The app came to the front or the network returned: a stream that is not live attaches again.
    func resumeSignal() {
        guard !left, onView else { return }
        guard status != nil || unavailable else {
            open()
            return
        }
        syncHealth()
        guard canAttach, conn != .live, conn != .attaching else { return }
        attach(auto: true, signal: true)
    }

    // MARK: Attach

    /// "Reconnect".
    func reconnect() { attach(auto: false) }

    private func attach(auto: Bool, signal: Bool = false) {
        guard !left, onView, canAttach else { return }
        if !auto || signal {
            rapidEvictions = 0
            lastFailureAt = signal ? lastFailureAt : nil
            ticketRetried = false
        }
        if !auto { autoRetry = false }
        retryTask?.cancel()
        retryTask = nil
        let prior = viewer
        detach()
        let generation = attachGeneration
        conn = .attaching
        AppLog.note("screen", "attach")
        changed()
        Task { [weak self] in await self?.runAttach(generation, prior: prior) }
    }

    private func runAttach(_ generation: Int, prior: ScreenViewer?) async {
        do {
            let value = try await env.client.call("display.observe", ScreenWire.observeParams(profile: profile, viewerId: prior?.id),
                                                  timeout: ScreenWire.observeTimeout)
            guard generation == attachGeneration, !left else { return }
            guard let observed = ScreenObserved.parse(value) else { throw RPCError(code: 5300, message: "The gateway’s answer could not be read.", data: nil) }
            let wasSeed = unverifiedSeed
            applyAuthoritative(observed.status)
            // Opened on a cached status that is out of date: the screen's own page, no stream.
            if wasSeed, !canAttach { afterStatus(); return }
            let minted = observed.viewer
            viewer = minted
            changed()
            // §5.8: the lease still names an id this app held on the old connection. Look again, then take it with
            // the new id.
            if ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: lease, own: env.holds.own(env.accountId, profile)) {
                let fresh = try? await env.client.call("display.status", ScreenWire.profileParams(profile), timeout: ScreenWire.statusTimeout)
                guard generation == attachGeneration, !left else { return }
                if let fresh, let recheck = ScreenStatus.parse(fresh) {
                    applyAuthoritative(recheck)
                    if ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: lease, own: env.holds.own(env.accountId, profile)) {
                        let got = try? await env.client.call("display.lease.acquire", ScreenWire.acquireParams(profile: profile, viewerId: minted.id),
                                                             timeout: ScreenWire.leaseTimeout)
                        if left {
                            // Closed while the acquire ran: do not leave the new id holding.
                            if got != nil { release(id: minted.id, forget: true) }
                            return
                        }
                        if let next = ScreenLease.parse(got?["lease"]) {
                            AppLog.note("screen", "lease reclaimed")
                            applyLease(next)
                        }
                        changed()
                        guard generation == attachGeneration else { return }
                    }
                }
            }
            let socket = try await env.dial(observed.path, observed.ticket)
            guard generation == attachGeneration, !left else {
                socket.close(handBack: false)
                return
            }
            dialedAt = env.now()
            let timing = env.timing
            let stream = ScreenStream(socket: socket, stuckAfter: timing.stuckAfter, firstPictureWait: timing.firstPictureWait,
                                      pingEvery: timing.pingEvery, now: env.now,
                                      onReady: { [weak self] width, height in self?.streamReady(generation, width, height) },
                                      onFrame: { [weak self] image, width, height, _ in self?.streamFrame(generation, image, width, height) },
                                      onEnd: { [weak self] end in self?.streamEnded(generation, end) })
            self.stream = stream
            stream.start()
        } catch {
            guard generation == attachGeneration, !left, !(error is CancellationError) else { return }
            if unverifiedSeed {
                // The cached status was stale (the screen was turned off, the gateway lost it): no "stream ended"
                // page, just the status read every other open makes.
                AppLog.note("screen", "known status was stale: reading it")
                unverifiedSeed = false
                status = nil
                framebuffer = nil
                conn = .idle
                open()
                return
            }
            AppLog.note("screen", "attach failed")
            let auto = autoRetry
            autoRetry = false
            conn = .error(title: Self.streamEnded, detail: auto ? nil : ScreenWire.sentence(ScreenWire.message(error)))
            changed()
            refresh()
        }
    }

    private func streamReady(_ generation: Int, _ width: Int, _ height: Int) {
        guard generation == attachGeneration, !left else { return }
        ticketRetried = false                       // this ticket was taken: a later one gets its own second try
        framebuffer = (width, height)
        changed()
    }

    private func streamFrame(_ generation: Int, _ image: CGImage, _ width: Int, _ height: Int) {
        guard generation == attachGeneration, !left else { return }
        if framebuffer?.width != width || framebuffer?.height != height {
            framebuffer = (width, height)
            pointer = pointer.map { (min($0.x, width - 1), min($0.y, height - 1)) }
            if conn == .live { changed() }
        }
        onFrame?(image, width, height)
        guard conn != .live else { return }
        conn = .live
        autoRetry = false
        AppLog.note("screen", "live")
        // DECISION D14: a button a dropped link left down is released before anything else is sent.
        if holding { clearButtons() }
        onNotice?(.live)
        changed()
    }

    private func streamEnded(_ generation: Int, _ end: ScreenStream.End) {
        guard generation == attachGeneration, !left else { return }
        stream = nil
        mask = 0
        stopTyping()
        var code: Int?
        var reason = ""
        if case .closed(let closeCode, let closeReason) = end {
            code = closeCode
            reason = closeReason ?? ""
        }
        AppLog.note("screen", "close \(code.map(String.init) ?? "none")")
        if end == .noPicture {
            // The socket was fine and the handshake finished: trying again by itself would only wait the same 20 s.
            // Say why instead of the bare "Screen Stopped" (the web's viewer just sat there under its notes).
            retryTask?.cancel()
            retryTask = nil
            lastFailureAt = nil
            autoRetry = false
            conn = .error(title: isMac ? Self.noPictureMac : Self.noPicture, detail: isMac ? Self.noPictureReason(health) : nil)
            changed()
            refresh()
            if isMac { Task { [weak self] in await self?.readHealth() } }       // the reason may be newer than the last poll
            return
        }
        if code == ScreenWire.Close.controlTaken || reason.contains("control-taken") {
            let now = env.now()
            rapidEvictions = now - dialedAt < env.timing.evictionWindow ? rapidEvictions + 1 : 1
            onNotice?(.controlTaken)
            if rapidEvictions > env.timing.maxEvictions {
                conn = .error(title: Self.controlTaken, detail: nil)
            } else {
                conn = .idle
                attach(auto: true)
            }
        } else if code == ScreenWire.Close.ticket {
            if ticketRetried {
                // The fresh ticket was refused too: say so. No third try by itself (the stress run counted three).
                retryTask?.cancel()
                retryTask = nil
                lastFailureAt = nil
                autoRetry = false
                conn = .error(title: Self.streamEnded, detail: nil)
            } else {
                ticketRetried = true                // a spent or expired ticket: observe again, once
                conn = .idle
                attach(auto: true)
            }
        } else if code == ScreenWire.Close.notRunning {
            // The status read below says what is true now (off, or running again). Twice inside the window is a
            // gateway that says both: stop and ask for a tap.
            let now = env.now()
            retryTask?.cancel()
            retryTask = nil
            if let last = lastFailureAt, now - last < env.timing.failureWindow {
                lastFailureAt = nil
                conn = .error(title: Self.streamEnded, detail: nil)
            } else {
                lastFailureAt = now
                conn = .idle
            }
        } else {
            unexpectedEnd()
        }
        changed()
        refresh()
    }

    /// Why a Mac that answered has no picture to send, from the helper's own health (the web's readiness wording).
    static func noPictureReason(_ health: JSONValue?) -> String? {
        let helper = health?["helper"]
        if helper?["paused"]?.bool == true { return "Resume sharing from Hermes HQ Screen’s menu on the Mac." }
        if let capture = helper?["capture_error"]?.string.map(ScreenWire.plain), !capture.isEmpty { return ScreenWire.sentence(capture) }
        if helper?["tcc"]?["screen"]?.bool == false { return "Allow Screen Recording for Hermes HQ Screen on the Mac." }
        if helper?["locked"]?.bool == true { return "The Mac is locked, and its display may be asleep. Wake it, then \(DeviceWord.tap) Reconnect." }
        return "Its display may be asleep. Wake the Mac, then \(DeviceWord.tap) Reconnect."
    }

    /// DECISION D11: one quiet re-attach after a second; a second failure inside the window asks for a tap.
    private func unexpectedEnd() {
        let now = env.now()
        if let last = lastFailureAt, now - last < env.timing.failureWindow {
            lastFailureAt = nil
            autoRetry = false
            conn = .error(title: Self.streamEnded, detail: nil)
            return
        }
        lastFailureAt = now
        conn = .attaching
        autoRetry = true
        let delay = env.timing.retryDelay
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard self.onView, self.canAttach else {
                self.conn = .idle
                self.changed()
                return
            }
            self.attach(auto: true)
        }
    }

    /// Ends the current attach without handing the lease back.
    private func detach() {
        attachGeneration += 1
        stopTyping()
        if let stream {
            stream.stop(handBack: false, flush: releaseMessages())
            self.stream = nil
        }
        mask = 0
    }

    // MARK: On view (§5.11)

    /// The viewer went out of view (`immediately` for the background, else after a second if still away) or came back.
    func setOnView(_ visible: Bool, immediately: Bool = false) {
        guard !left else { return }
        pauseTask?.cancel()
        pauseTask = nil
        if visible {
            // Already in view (the first appearance, or a look away shorter than the pause): nothing to resume. A
            // signal here re-attached a stream that had just ended in words (the stress run saw the refused-ticket
            // page try twice more when the viewer finished appearing).
            guard !onView else { return }
            onView = true
            AppLog.note("screen", "resume")
            resumeSignal()
            return
        }
        guard onView else { return }
        if immediately {
            pause()
            return
        }
        let delay = env.timing.pauseDelay
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pauseTask = nil
            self.pause()
        }
    }

    private func pause() {
        guard onView, !left else { return }
        onView = false
        AppLog.note("screen", "pause")
        retryTask?.cancel()
        retryTask = nil
        autoRetry = false
        detach()                                // a plain cancel: the lease is kept, as for a dropped link
        if conn != .idle, canAttach, !isError { conn = .idle }
        healthTask?.cancel()
        healthTask = nil
        changed()
    }

    private var isError: Bool {
        if case .error = conn { return true }
        return false
    }

    // MARK: Calls

    func start() {
        guard !left, busy == nil else { return }
        busy = .start
        changed()
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.env.client.call("display.start", ScreenWire.profileParams(self.profile), timeout: ScreenWire.startTimeout)
                guard !self.left else { return }
                self.busy = nil
                self.errorLine = nil
                if let parsed = ScreenStatus.parse(value) {
                    self.applyAuthoritative(parsed)
                    self.conn = .idle
                    self.afterStatus()
                } else {
                    self.changed()
                    self.refresh()
                }
            } catch {
                self.fail(error)
            }
        }
    }

    /// "Take over" and "Resume control".
    func takeOver() {
        guard !left, busy == nil, let viewer, canTake else { return }
        leaseCall(.take, ScreenWire.acquireParams(profile: profile, viewerId: viewer.id), method: "display.lease.acquire") { session in
            if session.conn != .live, session.conn != .attaching { session.attach(auto: false) }
        }
    }

    /// "Hand back": this attach's hold, or a hold this phone lost track of (released by its saved id).
    func handBack() {
        guard !left, busy == nil else { return }
        if holding, let viewer {
            releaseButtons()
            leaseCall(.give, ScreenWire.releaseParams(profile: profile, viewerId: viewer.id, force: false), method: "display.lease.release")
        } else if let held {
            leaseCall(.give, ScreenWire.releaseParams(profile: profile, viewerId: held.id, force: true), method: "display.lease.release") { session in
                session.env.holds.forget(session.env.accountId, session.profile)
            }
        }
    }

    /// "Hand back (force)": returns another viewer's control to the bot.
    func forceHandBack() {
        guard !left, busy == nil else { return }
        leaseCall(.force, ScreenWire.releaseParams(profile: profile, viewerId: nil, force: true), method: "display.lease.release")
    }

    private func leaseCall(_ kind: Busy, _ params: JSONValue, method: String, then: (@MainActor (ScreenSession) -> Void)? = nil) {
        busy = kind
        changed()
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.env.client.call(method, params, timeout: ScreenWire.leaseTimeout)
                guard !self.left else { return }
                self.busy = nil
                self.errorLine = nil                    // a call that worked clears an earlier failure
                if let next = ScreenLease.parse(value["lease"]) { self.applyLease(next) }
                AppLog.note("screen", self.holding ? "lease mine" : "lease changed")
                then?(self)
                self.changed()
            } catch {
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        guard !left else { return }
        busy = nil
        if !(error is CancellationError) { errorLine = ScreenWire.message(error) }
        changed()
    }

    func dismissError() {
        guard errorLine != nil else { return }
        errorLine = nil
        changed()
    }

    // MARK: Input (accepted only while this viewer holds the lease and the stream is live)

    /// A pointer message at a framebuffer pixel. The position is remembered for the next button change.
    func sendPointer(mask next: UInt8, x: Int, y: Int) {
        pointer = (x, y)
        guard canSendInput, let stream else { return }
        mask = next & 0b0000_0111                         // wheel bits are momentary
        stream.send(RFBMessage.pointer(mask: next, x: x, y: y))
    }

    func sendKeys(_ messages: [Data]) {
        guard canSendInput, let stream else { return }
        for message in messages { stream.send(message) }
    }

    /// Text typed key by key, 500 characters per turn of the run loop (DECISION D18); stops when control ends.
    func type(_ text: String, mods: Set<ScreenKeys.Modifier> = []) {
        guard canSendInput, !text.isEmpty else { return }
        typer.add(text, mods: mods)
        guard typeTask == nil else { return }
        typeToken += 1
        let token = typeToken
        typeTask = Task { [weak self] in
            while !Task.isCancelled, let self, token == self.typeToken, self.canSendInput, !self.typer.isEmpty {
                self.sendKeys(self.typer.next())
                await Task.yield()
            }
            guard let self, token == self.typeToken else { return }
            self.stopTyping()
        }
    }

    /// Text still waiting to be typed is dropped (hand back, control lost, the stream closing).
    private func stopTyping() {
        typeToken += 1
        typeTask?.cancel()
        typeTask = nil
        typer.cancel()
    }

    /// Characters still waiting to be typed (a long paste in progress).
    var typingBacklog: Int { typer.count }

    /// Paste: false when there is nothing to paste (the view says "There’s no text to paste.").
    @discardableResult func paste(_ text: String?) -> Bool {
        switch ScreenKeys.paste(text, mac: isMac) {
        case .empty: return false
        case .clipboard(let messages): sendKeys(messages)
        case .typed(let text): type(text)
        }
        return true
    }

    private func releaseMessages() -> [Data] {
        guard mask != 0, holding, let at = pointer ?? centre else { return [] }
        return [RFBMessage.pointer(mask: 0, x: at.x, y: at.y)]
    }

    private var centre: (x: Int, y: Int)? { framebuffer.map { ($0.width / 2, $0.height / 2) } }

    /// DECISION D14: button-up for a held pointer button before control is given away.
    private func releaseButtons() {
        stopTyping()
        for message in releaseMessages() { stream?.send(message) }
        mask = 0
    }

    private func clearButtons() {
        guard let stream, let at = pointer ?? centre else { return }
        mask = 0
        stream.send(RFBMessage.pointer(mask: 0, x: at.x, y: at.y))
    }

    // MARK: Mac health (§5.10)

    private func syncHealth() {
        guard isMac, onView, !left else {
            healthTask?.cancel()
            healthTask = nil
            return
        }
        guard healthTask == nil else { return }
        let every = env.timing.healthEvery
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readHealth()
                guard let slow = self?.env.slow() else { return }
                try? await Task.sleep(for: slow ? every * 2 : every)
            }
        }
    }

    private func readHealth() async {
        let value: JSONValue?
        do { value = try await env.health.read() } catch { return }                       // a failed read keeps the last value
        guard !left else { return }
        let parsed = MacScreen.parse(value)
        let same = parsed == mac && value == health
        health = value
        mac = parsed
        // "The Mac hasn’t sent a picture yet" says why in the helper's newest words.
        if case .error(title: Self.noPictureMac, let detail) = conn, detail != Self.noPictureReason(value) {
            conn = .error(title: Self.noPictureMac, detail: Self.noPictureReason(value))
            changed()
            return
        }
        if !same { changed() }
    }

    // MARK: Leaving (§5.8, §6.2)

    /// Close, and whatever sign-out or an account switch did not hand back first. Never waits on the network.
    func leave() {
        guard let (action, stream, flush) = depart() else { return }
        switch action {
        case .closeHandsBack:
            // The close frame 1000 hands the lease back. Nothing says here that it arrived, so the saved hold is not
            // forgotten on faith (review finding 2): the gateway's `display.lease` event forgets it (ScreenService),
            // or the next visit's status does; if neither comes, the next visit offers "You were in control".
            stream?.stop(handBack: true, flush: flush)
            env.holds.clearOwn(env.accountId, profile)             // this run does not take it back silently
        case .release(let id):
            stream?.stop(handBack: false, flush: flush)
            release(id: id, forget: true)
        case .nothing:
            stream?.stop(handBack: false)
        }
    }

    /// Sign-out and gateway switch, called while the client can still ask: leaves as `leave()` does and waits (at most
    /// about two seconds) for the gateway's own word that the bot has control again. Without that word the saved
    /// hold is kept, so the next launch offers Resume control / Hand back.
    func leaveConfirming(wait: Duration = .milliseconds(1500)) async {
        guard let (action, stream, flush) = depart() else { return }
        switch action {
        case .closeHandsBack:
            env.holds.clearOwn(env.accountId, profile)
            let id = viewer?.id
            await stream?.stopAndWait(handBack: true, flush: flush)     // the button-up, then the close frame, in order
            if let id { await confirmReleased(id: id, wait: wait) }
        case .release(let id):
            stream?.stop(handBack: false, flush: flush)
            await confirmReleased(id: id, wait: wait)
        case .nothing:
            stream?.stop(handBack: false)
        }
    }

    /// Everything `leave` does but the stream's close and the lease. nil: already left.
    private func depart() -> (ScreenHolds.Leave, ScreenStream?, [Data])? {
        guard !left else { return nil }
        let action = ScreenHolds.leave(holding: holding, streamOpen: stream != nil && conn == .live, viewer: viewer,
                                       saved: env.holds.saved(env.accountId, profile))
        let flush = action == .nothing ? [] : releaseMessages()
        left = true
        AppLog.note("screen", "leave")
        for task in [statusTimer, retryTask, pauseTask, healthTask] { task?.cancel() }
        attachGeneration += 1
        stopTyping()
        let stream = self.stream
        self.stream = nil
        onChange = nil
        onFrame = nil
        onNotice = nil
        return (action, stream, flush)
    }

    /// `display.lease.release {viewer_id, force}` answers with the lease as it now is (it is not an error when the
    /// close frame already gave it back). Only that answer forgets the hold.
    private func confirmReleased(id: String, wait: Duration) async {
        let hash = ScreenWire.viewerHash(id)
        guard let value = try? await env.client.call("display.lease.release", ScreenWire.releaseParams(profile: profile, viewerId: id, force: true),
                                                     timeout: wait),
              let lease = ScreenLease.parse(value["lease"]), !(lease.holder == .human && lease.viewerHash == hash) else {
            AppLog.note("screen", "hand-back not confirmed")
            return
        }
        let holds = env.holds, account = env.accountId
        if holds.saved(account, profile)?.id == id { holds.forget(account, profile) }
        if holds.own(account, profile)?.id == id { holds.clearOwn(account, profile) }
    }

    /// `display.lease.release {viewer_id, force}` in a task that outlives the viewer (bounded by the call's 10 s).
    /// Offline, nothing is forgotten: the next launch offers the hold again.
    private func release(id: String, forget: Bool) {
        let client = env.client, holds = env.holds, account = env.accountId, profile = self.profile
        Task {
            guard (try? await client.call("display.lease.release", ScreenWire.releaseParams(profile: profile, viewerId: id, force: true),
                                          timeout: ScreenWire.leaseTimeout)) != nil else { return }
            if forget {
                if holds.saved(account, profile)?.id == id { holds.forget(account, profile) }
                if holds.own(account, profile)?.id == id { holds.clearOwn(account, profile) }
            }
        }
    }

    // MARK: Bookkeeping

    private func changed() {
        guard !left else { return }
        env.holds.note(lease: lease, viewer: viewer, account: env.accountId, profile: profile)
        let now = holding
        if now != wasHolding {
            wasHolding = now
            if now {
                if conn == .live { clearButtons() }
                onNotice?(.controlStarted)
            } else {
                mask = 0
                stopTyping()
                onNotice?(.controlEnded)
            }
        }
        report?(self)
        onChange?()
    }
}

/// DECISION D9: the web's power-aware interval.
@MainActor enum ScreenPower {
    /// [settings] One reading for the whole app (`PowerState`), so a DEBUG override reaches the Screen viewer too.
    static var slow: Bool { PowerState.shared.saving }
}
