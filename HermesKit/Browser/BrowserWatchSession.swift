// One live view of a bot's browser (the plugin's `WS /sessions/{id}/watch`, stream.py): hello, the view size, state and
// frames in, acks out once a frame is drawn, the person's input while they hold it, and reconnects (port of the web
// app's viewer.tsx socket half). Frames are parsed and decoded off the main thread; the main thread only puts the
// decoded image on screen. No page content, typed text or address is ever logged.

import Foundation
import CoreGraphics
import ImageIO
import Synchronization

/// One decoding frame and one waiting: a newer frame replaces the one waiting (which is acknowledged unseen so the
/// plugin's window moves on); stale pixels are never shown. Decodes on its own queue.
nonisolated final class BrowserFrameDecoder: Sendable {
    struct Stats: Sendable { var decoded = 0; var mainThreadDecodes = 0; var skipped = 0; var failed = 0 }

    private let queue = DispatchQueue(label: "ai.hermes.hqnative.browser.decode", qos: .userInitiated)
    private let state = Mutex<(busy: Bool, waiting: BrowserFrame?, lastSeq: Int, closed: Bool, stats: Stats)>((false, nil, 0, false, Stats()))
    private let decoded: @Sendable (BrowserFrame, CGImage) -> Void
    private let skipped: @Sendable (Int) -> Void
    private let failed: @Sendable () -> Void

    /// `decoded` and `skipped` run on the decoder's queue.
    init(decoded: @escaping @Sendable (BrowserFrame, CGImage) -> Void, skipped: @escaping @Sendable (Int) -> Void,
         failed: @escaping @Sendable () -> Void) {
        self.decoded = decoded
        self.skipped = skipped
        self.failed = failed
    }

    var stats: Stats { state.withLock { $0.stats } }

    @discardableResult func push(_ frame: BrowserFrame) -> Bool {
        enum Step { case drop, start, wait(Int?) }
        let step = state.withLock { s -> Step in
            guard !s.closed, frame.seq > s.lastSeq else { return .drop }
            s.lastSeq = frame.seq
            if s.busy {
                let replaced = s.waiting?.seq
                if replaced != nil { s.stats.skipped += 1 }
                s.waiting = frame
                return .wait(replaced)
            }
            s.busy = true
            return .start
        }
        switch step {
        case .drop: return false
        case .wait(let replaced): if let replaced { skipped(replaced) }; return true
        case .start: queue.async { self.run(frame) }; return true
        }
    }

    func close() { state.withLock { $0.closed = true; $0.waiting = nil } }

    private func run(_ first: BrowserFrame) {
        var frame: BrowserFrame? = first
        while let current = frame {
            let image = Self.decode(current.jpeg)
            let closed = state.withLock { s -> Bool in
                if image != nil { s.stats.decoded += 1 } else { s.stats.failed += 1 }
                if Thread.isMainThread { s.stats.mainThreadDecodes += 1 }
                return s.closed
            }
            if closed { break }
            guard let image else { close(); failed(); break }
            decoded(current, image)
            frame = state.withLock { s -> BrowserFrame? in
                let next = s.closed ? nil : s.waiting
                s.waiting = nil
                if next == nil { s.busy = false }
                return next
            }
        }
        state.withLock { $0.busy = false }
    }

    /// A JPEG decoded now (not lazily at first draw on the main thread).
    static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// The frame pacing the viewer measured (DEBUG readout and the UI test's check).
nonisolated struct BrowserPacing: Sendable, Equatable {
    var frames = 0
    var medianMs = 0.0
    var p95Ms = 0.0
    var mainThreadDecodes = 0

    static func from(intervals: [Double], frames: Int, mainThreadDecodes: Int) -> BrowserPacing {
        let sorted = intervals.sorted()
        func at(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] * 1000 }
        return BrowserPacing(frames: frames, medianMs: at(0.5), p95Ms: at(0.95), mainThreadDecodes: mainThreadDecodes)
    }

    var summary: String { String(format: "frames=%d p50=%.0f p95=%.0f mainDecodes=%d", frames, medianMs, p95Ms, mainThreadDecodes) }
}

@MainActor final class BrowserWatchSession {
    enum Link: String { case idle, connecting, live, reconnecting, stalled }

    let service: BrowserService
    let rowId: String
    let base: String
    let profile: String
    let name: String

    private(set) var link: Link = .idle {
        didSet {
            guard link != oldValue else { return }
            AppLog.note("browser", "watch link \(link.rawValue)")
            MainTrail.set("browserLink", link.rawValue)       // [diagnostics] build 292: HangWatch's context
            onChange?()
        }
    }
    private(set) var view: BrowserViewState? { didSet { if view != oldValue { onChange?() } } }
    /// The page's CSS size and tab of the frame on screen (nil before the first).
    private(set) var page: (size: CGSize, tab: String?)?
    private(set) var ended = false
    private(set) var pacing = BrowserPacing()

    var onChange: (() -> Void)?
    /// A decoded frame to put on screen (main thread). Return after it is on screen: the ack follows.
    var onFrame: ((CGImage, BrowserFrame) -> Void)?
    /// A short notice (`warning`: with the warning haptic).
    var onNotice: ((String, Bool) -> Void)?
    /// The page's selected text, answering Copy.
    var onCopied: ((String) -> Void)?

    private var socket: BrowserSocket<BrowserServerMessage>?
    private var work: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var decoder: BrowserFrameDecoder?
    private var dials = 0
    private var attempt = 0
    private var stalled = false
    private var shown = false
    private var stopped = false
    private var pending = PendingTyping()
    private var nextAck = ContinuousClock.now
    private var lastInbound = ContinuousClock.now
    private var lastShown: CFTimeInterval?
    private var intervals: [Double] = []
    private var shownFrames = 0
    private let viewer = BrowserWire.viewerId()
    /// The stage size the frames are asked for (points × zoom) and the screen's scale.
    private var wantedView: (width: Double, height: Double, scale: Double)?

    init(service: BrowserService, rowId: String, base: String, profile: String, name: String) {
        self.service = service
        self.rowId = rowId
        self.base = base
        self.profile = profile
        self.name = name
        service.register(self)
    }

    /// The account went away (sign-out, another gateway): hand a held browser back, end, and tell the viewer.
    var onShutDown: (() -> Void)?

    func shutDown() {
        stop()
        onShutDown?()
    }

    #if DEBUG
    var isStopped: Bool { stopped }
    #endif

    var control: BrowserControlState? { view?.control }
    /// This phone holds the browser.
    var mine: Bool { control.map { $0.mine && $0.state == .person } ?? false }
    var waiting: Bool { control.map { $0.mine && $0.state == .waiting } ?? false }
    var someoneElse: Bool { control.map { $0.state != .bot && !$0.mine } ?? false }

    /// On screen and the app in front: the socket runs. Off: it closes (a held browser stays held two minutes).
    func setShown(_ on: Bool) {
        guard on != shown, !stopped else { return }
        shown = on
        if on { attempt = 0; connect() } else { disconnect() }
    }

    /// [presence] The gateway link is back (spec 3x-presence §11): a socket waiting out its back-off dials now, from the
    /// first step of the back-off. One that is live, or a dial already asking for its address, is left alone.
    func linkRestored() {
        guard BrowserLinkRule.watchDialsNow(shown: shown, stopped: stopped, ended: ended, hasSocket: socket != nil,
                                            retrying: retry != nil) else { return }
        retry?.cancel(); retry = nil
        attempt = 0
        AppLog.note("browser", "watch link restored: dialing now")
        connect()
    }

    /// The viewer closed: hand the browser back if this phone held it, then end.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if mine || waiting, let last = socket {
            // Its close waits for the Give Back to go out (audit 14-7), so disconnect() doesn't close it at once.
            socket = nil
            last.close(after: BrowserClientMessage.give.json(epoch: nil))
        }
        disconnect()
        AppLog.note("browser", "watch stopped")
    }

    private func disconnect() {
        dials += 1
        retry?.cancel(); retry = nil
        watchdog?.cancel(); watchdog = nil
        work?.cancel(); work = nil
        decoder?.close(); decoder = nil
        socket?.close(); socket = nil
        if link != .idle { link = .idle }
    }

    @discardableResult func send(_ message: BrowserClientMessage, epoch: Int? = nil) -> Bool {
        guard let socket, link == .live || message == .give || message == .take else { return false }
        socket.send(message.json(epoch: epoch))
        return true
    }

    /// The stage changed size or zoom: frames are sized to match (the plugin caps them).
    func setViewSize(width: Double, height: Double, scale: Double) {
        let size = browserViewSize(width: width, height: height, scale: scale)
        let wanted = (Double(size.width), Double(size.height), size.scale)
        if let old = wantedView, old == wanted { return }
        wantedView = wanted
        sendView()
    }

    private func sendView() {
        guard let wanted = wantedView, let socket else { return }
        socket.send(BrowserClientMessage.view(width: Int(wanted.width), height: Int(wanted.height), scale: wanted.scale).json())
    }

    // MARK: Control and input

    func take() { onNotice?("", false); send(.take) }
    func give() { send(.give) }
    func follow() { send(.follow) }
    func showTab(_ id: String) { send(.tab(id)) }

    /// Input while holding the browser. Typing during a socket blip waits for the socket (in order) instead of
    /// vanishing; a tap or a scroll at a stale spot is not replayed.
    func input(_ input: BrowserInput) {
        guard mine, let epoch = control?.epoch else { return }
        if !pending.isEmpty || link != .live || socket == nil {
            switch pending.add(input) {
            case .first: onNotice?("Reconnecting… What you type is sent when it’s back.", false)
            case .full: onNotice?("That’s too much to keep while reconnecting. Type the rest once it’s back.", true)
            default: break
            }
            return
        }
        send(.input(input), epoch: epoch)
    }

    /// Back on the browser after a reconnect: what was typed meanwhile goes to the page, or the person hears it didn't.
    private func sendTyped(_ state: BrowserViewState) {
        if state.control.mine && state.control.state == .waiting { return }
        let typed = pending.take()
        guard !typed.isEmpty else { return }
        guard state.control.mine, state.control.state == .person, let epoch = state.control.epoch else {
            onNotice?("What you typed while reconnecting wasn’t sent: \(name) has its browser back.", true)
            return
        }
        for input in typed { send(.input(input), epoch: epoch) }
    }

    // MARK: The socket

    private func connect() {
        guard shown, !stopped else { return }
        guard !service.isShutDown else { finish(); return }
        dials += 1
        let dial = dials
        link = stalled ? .stalled : (attempt > 0 || page != nil) ? .reconnecting : .connecting
        let path = BrowserWire.watchPath(rowId, base: base) ?? ""
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let task = try await self.service.sockets.pluginSocket(path: path, query: [URLQueryItem(name: "profile", value: self.profile)])
                guard dial == self.dials else { task.cancel(with: .normalClosure, reason: nil); return }
                let socket = BrowserSocket<BrowserServerMessage>(task: task, parse: BrowserServerMessage.parse)
                self.socket = socket
                self.nextAck = .now
                self.lastInbound = .now
                let decoder = self.makeDecoder(dial: dial)
                self.decoder = decoder
                socket.send(BrowserClientMessage.hello(viewer: self.viewer).json())
                self.sendView()
                self.startWatchdog(dial: dial)
                var closeCode = 1006
                for await event in socket.events {
                    guard dial == self.dials else { return }
                    switch event {
                    case .message(let message):
                        self.lastInbound = .now
                        if self.handle(message, socket: socket, decoder: decoder) { return }
                    case .closed(let code):
                        closeCode = code
                    }
                }
                guard dial == self.dials else { return }
                self.closed(code: closeCode)
            } catch {
                guard dial == self.dials, !Task.isCancelled else { return }
                if BrowserService.isMissing(error) { AppLog.note("browser", "watch ended: plugin missing"); self.finish(); return }
                AppLog.swallowed("browser", "open the watch socket", error)
                self.onNotice?((error as? LocalizedError)?.errorDescription ?? "Check your connection, then try again.", false)
                self.scheduleRetry()
            }
        }
    }

    private func makeDecoder(dial: Int) -> BrowserFrameDecoder {
        BrowserFrameDecoder(
            decoded: { [weak self] frame, image in
                Task { @MainActor [weak self] in self?.show(frame, image, dial: dial) }
            },
            skipped: { [weak self] seq in
                Task { @MainActor [weak self] in
                    guard let self, dial == self.dials else { return }
                    self.socket?.send(BrowserClientMessage.ack(seq: seq).json())
                }
            },
            failed: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, dial == self.dials else { return }
                    self.socket?.close(4000)
                }
            })
    }

    /// true: the stream is over for this dial.
    private func handle(_ message: BrowserServerMessage, socket: BrowserSocket<BrowserServerMessage>, decoder: BrowserFrameDecoder) -> Bool {
        switch message {
        case .state(let state):
            attempt = 0
            stalled = false
            view = state
            link = .live
            sendTyped(state)
        case .frame(let frame):
            decoder.push(frame)
        case .ping:
            socket.send(BrowserClientMessage.pong.json())     // a silent phone is let go
        case .error(let text):
            onNotice?(text, true)
        case .copied(let text):
            onCopied?(text)
        case .ended(let reason):
            // A browser that doesn't answer may be busy or restarting, and a stream error is the gateway's: connect
            // again either way. Closed is final.
            if reason == "unresponsive" { stalled = true; AppLog.note("browser", "watch stalled: unresponsive"); socket.close(); return false }
            if reason == "error" { AppLog.note("browser", "watch reconnecting: gateway stream error"); socket.close(); return false }
            finish()
            return true
        }
        return false
    }

    private func show(_ frame: BrowserFrame, _ image: CGImage, dial: Int) {
        guard dial == dials, let socket else { return }
        MainTrail.measure("browser.frame") { onFrame?(image, frame) }   // [diagnostics] build 292
        let size = CGSize(width: frame.width, height: frame.height)
        let changed = page.map { $0.size != size || $0.tab != frame.tab } ?? true
        page = (size, frame.tab)
        // Pacing: the time between frames put on screen.
        let now = CACurrentMediaTimeShim.now()
        if let last = lastShown { intervals.append(now - last); if intervals.count > 240 { intervals.removeFirst(intervals.count - 240) } }
        lastShown = now
        shownFrames += 1
        if shownFrames % 15 == 0 {
            pacing = BrowserPacing.from(intervals: intervals, frames: shownFrames, mainThreadDecodes: decoder?.stats.mainThreadDecodes ?? 0)
        }
        if changed { onChange?() }
        // Acks paced at `frameInterval`: the plugin sends a frame per ack, so this caps the frame rate.
        let clock = ContinuousClock.now
        let at = max(clock, nextAck)
        nextAck = at + BrowserWire.frameInterval
        let ack = BrowserClientMessage.ack(seq: frame.seq).json()
        if at > clock {
            Task { [weak self] in
                try? await Task.sleep(until: at, clock: .continuous)
                guard let self, dial == self.dials else { return }
                socket.send(ack)
            }
        } else {
            socket.send(ack)
        }
    }

    /// The server pings every 10 s; a socket that says nothing for 25 s is half-open: dial again.
    private func startWatchdog(dial: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, dial == self.dials, !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastInbound > .seconds(25) {
                    AppLog.note("browser", "watch socket silent; reconnecting")
                    self.socket?.close()
                    return
                }
            }
        }
    }

    private func closed(code: Int) {
        socket = nil
        decoder?.close(); decoder = nil
        watchdog?.cancel(); watchdog = nil
        if code == 4404 { finish(); return }
        scheduleRetry()
    }

    private func scheduleRetry() {
        attempt += 1
        link = stalled ? .stalled : .reconnecting
        let wait = BrowserReconnect.delay(attempt: attempt)
        let dial = dials
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, dial == self.dials else { return }
            self.retry = nil
            self.connect()
        }
    }

    /// The browser closed (the bot's turn ended it, or it is gone): no reconnect.
    private func finish() {
        ended = true
        view = nil
        page = nil
        pending.clear()
        disconnect()
        AppLog.note("browser", "watch ended")
        onChange?()
    }

    #if DEBUG
    /// Tests: feed a parsed message as the socket would.
    func debugReceive(_ message: BrowserServerMessage) {
        if case .state(let state) = message { view = state; link = .live; sendTyped(state) }
    }
    var debugPending: [BrowserInput] { pending.items }
    /// [presence] Tests: how many times it dialled, its back-off step, and whether it is waiting to retry.
    var debugDials: Int { dials }
    var debugAttempt: Int { attempt }
    var debugRetrying: Bool { retry != nil }
    #endif
}

/// `CACurrentMediaTime` without importing QuartzCore into HermesKit's pure files.
nonisolated enum CACurrentMediaTimeShim {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
